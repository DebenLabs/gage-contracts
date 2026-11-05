// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// How a listing gets funded, read on a fork of Robinhood Chain mainnet: the fill configuration of every Intent
// generation (factory, fill router, quote verifier, quote signer, fee recipient), a fill refused without gage's signed
// plan, and the most recent past fill decoded from its events and checked against the chain.
//
// Run from examples/foundry:
//   forge test --match-path test/Fills.t.sol -vv
//
// Nothing here impersonates gage's keeper, signer, routers or owner. Only an admitted filler can fill, on a plan gage's
// rates service signed; this file reads what those fills left on chain.

import {MainnetFork} from "./MainnetFork.sol";
import {Vm} from "forge-std/Vm.sol";

interface IIntentFactoryFills {
    function CORE() external view returns (address);
    function fillRouter() external view returns (address);
    function boundFillRouter() external view returns (address);
    function quoteSigner() external view returns (address);
    function protocolRecipient() external view returns (address);
    function isFiller(address filler) external view returns (bool);
    function isVault(address vault) external view returns (bool);
}

/// @dev `IntentFillRouter` (src/intent/IntentFillRouter.sol).
interface IFillRouter {
    function VERIFIER() external view returns (address);
    function FACTORY() external view returns (address);
    function CORE() external view returns (address);
    function USDG() external view returns (address);
    function owed(address recipient) external view returns (uint256);
    function totalOwed() external view returns (uint256);
}

/// @dev `IntentQuoteVerifier` (src/intent/IntentQuoteVerifier.sol): its plan structs, field for field.
interface IQuoteVerifier {
    struct Allocation {
        address vault;
        uint8 units;
        uint128 principal;
        uint128 interest;
        uint128 minimum;
        uint128 executionFee;
        uint128 maxReserveShares;
        uint8 minRateGrade;
        uint16 capBps;
        uint16 managerBps;
    }

    struct Plan {
        address engine;
        uint256 listingId;
        address filler;
        address token;
        uint8 kind;
        uint256 collateral;
        uint128 principal;
        uint128 cap;
        uint32 term;
        uint32 costBps;
        uint32 feePolicy;
        uint64 epoch;
        uint40 issuedAt;
        uint40 expiry;
        bytes32 evidence;
        Allocation[] allocations;
    }

    function FACTORY() external view returns (address);
    function CORE() external view returns (address);
    function MAX_QUOTE_LIFE() external view returns (uint40);
    function MAX_RESERVE_TOLERANCE_BPS() external view returns (uint16);
    function FEE_POLICY_VERSION() external view returns (uint32);
    function SECONDARY_POLICY_VERSION() external view returns (uint32);
    function epoch() external view returns (uint64);
    function consumed(bytes32 digest) external view returns (bool);
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
}

interface IFillRouterWrite {
    function fill(IQuoteVerifier.Plan calldata plan, bytes calldata signature, uint256[] calldata maxReserveShares)
        external
        returns (bytes32 digest);
}

/// @dev What every protocol fee recipient answers (src/interfaces/IIntentFeeProcessor.sol).
interface IFeeProcessor {
    function USDG() external view returns (address);
    function availableUSDG() external view returns (uint256);
}

/// @dev The core's loan record (src/v2/V2Types.sol `V2Loan`); its enums are `uint8` in the ABI.
struct CoreLoan {
    address originator;
    address account;
    address token;
    address collateralBeneficiary;
    uint8 kind;
    uint8 state;
    uint8 filled;
    uint32 term;
    uint40 fundingDeadline;
    uint40 fundedAt;
    uint40 closedAt;
    uint128 principal;
    uint128 cap;
    uint128 originationFee;
    uint128 borrowerReward;
    uint128 lenderReward;
    uint256 collateral;
    bytes32 exposureKey;
    uint256 exposureAmount;
}

interface ICoreMin {
    function USDG() external view returns (address);
    function getLoan(uint256 id) external view returns (CoreLoan memory);
    function lenders(uint256 id) external view returns (address[4] memory);
}

contract FillsTest is MainnetFork {
    bytes32 internal constant FILLED = keccak256("Filled(bytes32,uint256,address,uint40,uint256,uint256,address)");
    bytes32 internal constant CONTRIBUTION = keccak256("Contribution(bytes32,address,uint8,uint256,uint256,uint256)");

    /// @dev The manifest entries of every live generation: `intentV1` (USDG) and each `intentV1Assets.<SYMBOL>`.
    function _generations() internal view returns (string[] memory keys) {
        string[] memory symbols =
            has("intentV1Assets") ? vm.parseJsonKeys(manifest, ".intentV1Assets") : new string[](0);
        keys = new string[](symbols.length + 1);
        keys[0] = "intentV1";
        for (uint256 i; i < symbols.length; ++i) {
            keys[i + 1] = string.concat("intentV1Assets.", symbols[i]);
        }
    }

    function test_FillConfiguration() public view {
        string[] memory gens = _generations();
        for (uint256 i; i < gens.length; ++i) {
            string memory g = gens[i];
            IIntentFactoryFills factory = IIntentFactoryFills(addressOf(string.concat(g, ".factory")));
            address core = addressOf(string.concat(g, ".core"));
            IFillRouter router = IFillRouter(addressOf(string.concat(g, ".fillRouter")));
            IQuoteVerifier verifier = IQuoteVerifier(addressOf(string.concat(g, ".quoteVerifier")));

            // One router per factory, bound for good; the owner can only close fills (zero) and reopen them with it.
            assertEq(factory.CORE(), core);
            assertEq(factory.fillRouter(), address(router), "fills are open through the manifest's router");
            assertEq(factory.boundFillRouter(), address(router));
            assertEq(router.FACTORY(), address(factory));
            assertEq(router.CORE(), core);
            assertEq(router.VERIFIER(), address(verifier));
            assertEq(router.USDG(), ICoreMin(core).USDG(), "the router pays fees in the generation's lend asset");
            assertEq(verifier.FACTORY(), address(factory));
            assertEq(verifier.CORE(), core);

            // A plan is valid only if signed by the factory's quote signer, at most five minutes before it is used.
            assertTrue(factory.quoteSigner() != address(0), "a quote signer is named");
            // gage's keeper wallet, the manifest's `rolloverExecutor`, is the wallet admitted to fill. gage's loop,
            // private-borrow and rollover routers are admitted too: they fill inside their own transactions.
            if (has("rolloverExecutor")) assertTrue(factory.isFiller(addressOf("rolloverExecutor")));
            assertEq(verifier.MAX_QUOTE_LIFE(), 5 minutes);
            assertEq(verifier.FEE_POLICY_VERSION(), 1);
            assertEq(verifier.SECONDARY_POLICY_VERSION(), 2);
            assertEq(verifier.MAX_RESERVE_TOLERANCE_BPS(), 100);
            (, string memory name, string memory version, uint256 chainId, address verifying,,) =
                verifier.eip712Domain();
            assertEq(name, "gage Intent quotes");
            assertEq(version, "1");
            assertEq(chainId, block.chainid);
            assertEq(verifying, address(verifier));

            // Every execution fee goes to the factory's protocol recipient: DealFeeRouter for USDG, the generation's
            // fee processor for a lend asset. It must answer as a fee processor of the core's lend asset.
            address recipient = factory.protocolRecipient();
            address expected = i == 0 ? addressOf("DealFeeRouter") : addressOf(string.concat(g, ".feeProcessor"));
            assertEq(recipient, expected);
            assertEq(IFeeProcessor(recipient).USDG(), ICoreMin(core).USDG());
            IFeeProcessor(recipient).availableUSDG();
            assertLe(router.owed(recipient), router.totalOwed());
        }
    }

    /// @notice Anyone may call `fill`, but the verifier refuses a plan the factory's quote signer did not sign.
    function test_FillWithoutSignedPlanIsRefused() public {
        IFillRouterWrite router = IFillRouterWrite(addressOf("intentV1.fillRouter"));
        IQuoteVerifier.Plan memory plan;
        plan.engine = addressOf("intentV1.core");
        plan.filler = address(this);
        plan.issuedAt = uint40(block.timestamp);
        plan.expiry = uint40(block.timestamp + 60);
        // `Refused(Refusal)`: the enum is a uint8 in the ABI; BAD_SIGNATURE is 2.
        vm.expectRevert(abi.encodeWithSignature("Refused(uint8)", uint8(2)));
        router.fill(plan, new bytes(65), new uint256[](0));
    }

    /// @dev One `Filled` event, decoded.
    struct Fill {
        address router;
        bytes32 digest;
        uint256 listingId;
        address filler;
        uint40 activatedAt;
        uint256 principal;
        uint256 executionFee;
        address recipient;
        uint256 blockNumber;
        bytes32 txHash;
    }

    /// @notice The most recent fill of the USDG generation, or of the one it replaced while the new one has none yet,
    /// decoded from `Filled` and `Contribution` and checked against the verifier, the factory and the core.
    function test_DecodeLatestFill() public {
        address router = addressOf("intentV1.fillRouter");
        (bool found, Vm.EthGetLogs memory log_) = _latest(router, _uint("intentV1.startBlock"));
        if (!found && has("intentV1Previous")) {
            router = addressOf("intentV1Previous[0].intentV1.fillRouter");
            (found, log_) = _latest(router, _uint("intentV1Previous[0].intentV1.startBlock"));
        }
        if (!found) {
            vm.skip(true); // no fill to decode yet
            return;
        }
        Fill memory f = _decode(router, log_);
        _checkFill(f);
        _checkContributions(f);
        emit log_named_address("fill router", f.router);
        emit log_named_bytes32("plan digest", f.digest);
        emit log_named_uint("listing", f.listingId);
        emit log_named_uint("block", f.blockNumber);
        emit log_named_uint("principal (raw)", f.principal);
        emit log_named_uint("execution fee (raw)", f.executionFee);
        emit log_named_address("fee credited to", f.recipient);
    }

    /// @dev `Filled(bytes32 indexed digest, uint256 indexed listingId, address indexed filler, uint40 activatedAt,
    /// uint256 principal, uint256 executionFee, address protocolRecipient)`.
    function _decode(address router, Vm.EthGetLogs memory log_) internal pure returns (Fill memory f) {
        f.router = router;
        f.digest = log_.topics[1];
        f.listingId = uint256(log_.topics[2]);
        f.filler = address(uint160(uint256(log_.topics[3])));
        (f.activatedAt, f.principal, f.executionFee, f.recipient) =
            abi.decode(log_.data, (uint40, uint256, uint256, address));
        f.blockNumber = log_.blockNumber;
        f.txHash = log_.transactionHash;
    }

    function _checkFill(Fill memory f) internal {
        IFillRouter r = IFillRouter(f.router);
        IQuoteVerifier verifier = IQuoteVerifier(r.VERIFIER());
        IIntentFactoryFills factory = IIntentFactoryFills(r.FACTORY());
        // The plan's EIP-712 digest is recorded as used, for good.
        assertTrue(verifier.consumed(f.digest), "the plan was consumed");
        // The filler the plan named had to be admitted (`isFiller`) when it filled; this reads it at the fork block.
        emit log_named_address("filler", f.filler);
        emit log_named_string("filler admitted now", factory.isFiller(f.filler) ? "yes" : "no");
        if (has("rolloverExecutor")) {
            emit log_named_string(
                "filler is gage's keeper wallet",
                f.filler == addressOf("rolloverExecutor") ? "yes" : "no (a gage router)"
            );
        }
        // The listing activated in the fill's own transaction, for the whole principal.
        CoreLoan memory l = ICoreMin(r.CORE()).getLoan(f.listingId);
        assertEq(l.fundedAt, f.activatedAt, "activated at the fill");
        assertEq(l.principal, f.principal, "the plan funds the whole principal");
    }

    /// @dev `Contribution(bytes32 indexed digest, address indexed vault, uint8 units, uint256 principal,
    /// uint256 interest, uint256 fee)`: one per vault, in the fill's transaction, adding up to the fill.
    function _checkContributions(Fill memory f) internal {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = CONTRIBUTION;
        topics[1] = f.digest;
        Vm.EthGetLogs[] memory parts = vm.eth_getLogs(f.blockNumber, f.blockNumber, f.router, topics);
        assertGt(parts.length, 0);
        IIntentFactoryFills factory = IIntentFactoryFills(IFillRouter(f.router).FACTORY());
        address[4] memory lenders = ICoreMin(IFillRouter(f.router).CORE()).lenders(f.listingId);
        uint256 sumPrincipal;
        uint256 sumFee;
        uint256 units;
        for (uint256 i; i < parts.length; ++i) {
            assertEq(parts[i].transactionHash, f.txHash);
            address vault = address(uint160(uint256(parts[i].topics[2])));
            (uint8 u, uint256 p,, uint256 fee) = abi.decode(parts[i].data, (uint8, uint256, uint256, uint256));
            assertTrue(factory.isVault(vault), "only the factory's vaults fund");
            sumPrincipal += p;
            sumFee += fee;
            units += u;
            uint256 held;
            for (uint256 q; q < 4; ++q) {
                if (lenders[q] == vault) ++held;
            }
            emit log_named_address("vault", vault);
            emit log_named_uint("  quarters bought", u);
            emit log_named_uint("  principal (raw)", p);
            emit log_named_uint("  execution fee (raw)", fee);
            emit log_named_uint("  quarters it holds on the core now", held);
        }
        assertEq(units, 4, "a fill takes all four quarters");
        assertEq(sumPrincipal, f.principal);
        assertEq(sumFee, f.executionFee);
    }

    /// @dev The newest `Filled` log of `router`, searched back from the fork block in windows the public RPC serves.
    function _latest(address router, uint256 fromBlock) internal view returns (bool, Vm.EthGetLogs memory last) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = FILLED;
        uint256 window = 2_000_000;
        for (uint256 to = block.number; to >= fromBlock;) {
            uint256 from = to > fromBlock + window ? to - window : fromBlock;
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(from, to, router, topics);
            if (logs.length != 0) return (true, logs[logs.length - 1]);
            if (from == fromBlock) break;
            to = from - 1;
        }
        return (false, last);
    }

    function _uint(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(manifest, string.concat(".", key));
    }
}

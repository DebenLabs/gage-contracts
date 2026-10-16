// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IntentPlanBaseTest} from "../intent/IntentPlanBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {Kind} from "../../src/types/Types.sol";
import {PrivateBorrowRouter} from "../../src/private/PrivateBorrowRouter.sol";
import {IPrivacyPoolsEntrypoint} from "../../src/private/IPrivacyPools.sol";

/// @notice What both private-lane suites share: the real fill router, the router under test wired into the core and the
/// factory, the plans an honest signer produces ahead of a listing, and the screener's root attestations.
abstract contract PrivateLaneBaseTest is IntentPlanBaseTest {
    IntentFillRouter internal fills;
    PrivateBorrowRouter internal lane;

    address internal fresh = makeAddr("fresh-wallet");
    address internal relayer = makeAddr("relayer");
    address internal payout = makeAddr("payout");

    uint256 internal constant ATTESTER_KEY = 0xA77E57;
    uint256 internal constant COLLATERAL = 100e18;
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant ATTESTATION_TYPEHASH =
        keccak256("RootAttestation(uint256 root,address token,uint40 issuedAt,uint40 validUntil)");

    function _deployRouter() internal override returns (address) {
        fills = new IntentFillRouter(IntentQuoteVerifier(address(verifier)), IERC20(address(usdg)));
        return address(fills);
    }

    /// @dev The router under test, admitted by the registry and the factory, with a cap on the fixture token.
    function _deployLane(address entrypoint) internal {
        lane = new PrivateBorrowRouter(fills, IPrivacyPoolsEntrypoint(entrypoint), vm.addr(ATTESTER_KEY), address(this));
        vm.prank(safe);
        registry.setRouter(address(lane), true);
        partnerFactory.setFiller(address(lane), true);
        lane.setTokenCap(address(nvda), 5000e6);
    }

    function _shares(uint256 count) internal pure returns (uint256[] memory limits) {
        limits = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            limits[i] = type(uint256).max;
        }
    }

    /// @dev The plan an honest signer produces for a listing that does not exist yet: all four units empty.
    function _planAhead(uint256 id, address token, uint256 collateral, uint128 principal, uint128 cap, uint8 a, uint8 b)
        internal
        view
        returns (IntentQuoteVerifier.Plan memory p)
    {
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(a, b);
        p.engine = address(core);
        p.listingId = id;
        p.filler = address(lane);
        p.token = token;
        p.kind = uint8(Kind.ERC20);
        p.collateral = collateral;
        p.principal = principal;
        p.cap = cap;
        p.term = T21;
        p.costBps = COST_BPS;
        p.feePolicy = verifier.FEE_POLICY_VERSION();
        p.epoch = verifier.epoch();
        p.issuedAt = uint40(block.timestamp);
        p.expiry = uint40(block.timestamp + 90);
        p.evidence = keccak256("private lane evidence");
        p.allocations = new IntentQuoteVerifier.Allocation[](vaults.length);
        uint8 next;
        for (uint256 i; i < vaults.length; ++i) {
            IntentQuoteVerifier.Allocation memory al = p.allocations[i];
            al.vault = address(vaults[i]);
            al.units = counts[i];
            uint256 owed;
            for (uint8 left = counts[i]; left != 0; --left) {
                al.principal += uint128(principal / 4 + (next < principal % 4 ? 1 : 0));
                owed += cap / 4 + (next < cap % 4 ? 1 : 0);
                ++next;
            }
            al.interest = uint128(owed - al.principal);
            al.minRateGrade = vaults[i].minRateGrade();
            al.capBps = vaults[i].executionCapBps();
            al.managerBps = vaults[i].feeBps();
            al.minimum = uint128(IntentFeeMath.minimumInterest(al.principal, p.costBps, al.minRateGrade));
            (, uint256 fee) = IntentFeeMath.executionFee(al.interest, al.minimum, al.capBps);
            al.executionFee = uint128(fee);
            al.maxReserveShares = uint128(vaults[i].RESERVE().previewWithdraw(uint256(al.principal) + fee));
        }
    }

    function _terms(uint128 principal, uint128 cap) internal view returns (PrivateBorrowRouter.Terms memory) {
        return PrivateBorrowRouter.Terms({
            borrower: fresh,
            principal: principal,
            cap: cap,
            term: T21,
            fundingDeadline: uint40(block.timestamp + 1 days),
            withRewards: true
        });
    }

    function _digest(address router, uint256 chainId, uint256 root, address token, uint40 issuedAt, uint40 validUntil)
        internal
        pure
        returns (bytes32)
    {
        bytes32 domain =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("gage private lane"), keccak256("1"), chainId, router));
        bytes32 structHash = keccak256(abi.encode(ATTESTATION_TYPEHASH, root, token, issuedAt, validUntil));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _attestWith(
        uint256 key,
        address router,
        uint256 chainId,
        uint256 root,
        address token,
        uint40 issuedAt,
        uint40 validUntil
    ) internal pure returns (PrivateBorrowRouter.RootAttestation memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(router, chainId, root, token, issuedAt, validUntil));
        return PrivateBorrowRouter.RootAttestation(root, token, issuedAt, validUntil, abi.encodePacked(r, s, v));
    }

    /// @dev What the screener signs while the lane is healthy for the fixture token: this root, for two minutes from now.
    function _attest(uint256 root) internal view returns (PrivateBorrowRouter.RootAttestation memory) {
        uint40 at = uint40(block.timestamp);
        return _attestWith(ATTESTER_KEY, address(lane), block.chainid, root, address(nvda), at, at + 2 minutes);
    }
}

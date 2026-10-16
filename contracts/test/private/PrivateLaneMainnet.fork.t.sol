// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PrivateLaneBaseTest} from "./PrivateLaneBase.t.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {PrivateBorrowRouter} from "../../src/private/PrivateBorrowRouter.sol";
import {IPrivacyPool, IPrivacyPoolsEntrypoint} from "../../src/private/IPrivacyPools.sol";

/// @dev The Privacy Pools v1.3.0 Entrypoint calls the release makes and this suite exercises.
interface IEntrypointRelease {
    function initialize(address owner, address postman) external;
    function registerPool(
        address asset,
        address pool,
        uint256 minimumDepositAmount,
        uint256 vettingFeeBPS,
        uint256 maxRelayFeeBPS
    ) external;
    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address callerConfirmation) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function deposit(address asset, uint256 value, uint256 precommitment) external returns (uint256 commitment);
    function updateRoot(uint256 root, string memory ipfsCID) external returns (uint256 index);
    function latestRoot() external view returns (uint256);
    function assetConfig(address asset)
        external
        view
        returns (address pool, uint256 minimumDepositAmount, uint256 vettingFeeBPS, uint256 maxRelayFeeBPS);
}

interface IPoolView {
    function SCOPE() external view returns (uint256);
    function ASSET() external view returns (address);
    function nullifierHashes(uint256 nullifierHash) external view returns (bool);
}

interface IPoseidon {
    function hash(uint256[2] memory input) external pure returns (uint256);
}

/// @notice The private lane on a LOCAL fork of Robinhood Chain mainnet (4663) as the go-live release deploys it, before
/// it exists there: 0xbow's Privacy Pools v1.3.0 from the pinned build (fixtures/privacy-pools-v1.3.0.json, the bytes
/// scripts/privacy-pools-build.mjs reproduces from 0xbow's tag) linked to the canonical Poseidon libraries already on
/// 4663, a pool for a real 4663 memecoin (CASHCAT) and one for a real ecosystem token (PONS), and the Entrypoint handed
/// to the Safe the way scripts/lib/release/private-lane.mjs does it. The router is deployed with every cap at zero and
/// handed to the Safe (batch 01), then admitted and capped by the Safe (batch 02), against a fresh Intent core on the
/// fork (the shared fixture, with strategies for the two tokens). Each case makes a real deposit of the token, posts the
/// screener's root with a test postman, attests it with a test attester key, proves a withdrawal with a real Groth16
/// proof (web/scripts/private-prove.ts through ffi, over the circuit files 0xbow's SDK pins), borrows through a relayer,
/// repays, and checks that `release` returns the cap.
/// @dev Skipped unless PRIVATE_LANE_FORK_URL names the read-only relay (a loopback URL; never a keyed RPC). Needs `--ffi`
/// and the circuit files (PRIVACY_POOLS_CIRCUITS, or web/.cache/privacy-pools-circuits: `pnpm --filter ./web circuits`).
/// Nothing is signed for or sent to any chain.
contract PrivateLaneMainnetForkTest is PrivateLaneBaseTest {
    struct Note {
        uint256 value;
        uint256 label;
        uint256 nullifier;
        uint256 secret;
    }

    struct Args {
        address pool;
        IPrivacyPool.WithdrawProof proof;
        PrivateBorrowRouter.Terms terms;
        PrivateBorrowRouter.RootAttestation attestation;
        IntentQuoteVerifier.Plan plan;
        bytes signature;
    }

    /// @dev launch/mainnet.release.json contracts.categories: CASHCAT is MEME (1), PONS is RH_ECOSYSTEM (2).
    address internal constant CASHCAT = 0x020bfC650A365f8BB26819deAAbF3E21291018b4;
    address internal constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    /// @dev The mainnet Safe (scripts/lib/release/networks.mjs MAINNET_SAFE): the Entrypoint's and the router's owner.
    address internal constant MAINNET_SAFE = 0x30e8E13E62DFcd063AF763aB29501FeE74C4918e;
    address internal constant POSEIDON_T3 = 0x3333333C0A88F9BE4fd23ed0536F9B6c427e3B93;
    address internal constant POSEIDON_T4 = 0x4443338EF595F44e0121df4C21102677B142ECF0;
    /// @dev scripts/lib/privacy-pools.mjs POSEIDON_CODE_HASH: the canonical libraries' code on 4663 and 46630.
    bytes32 internal constant POSEIDON_T3_CODE = 0x4495c92f7f5db02c3922c3e56cbe427af9cb349a77fd3faf41165afb3137d022;
    bytes32 internal constant POSEIDON_T4_CODE = 0xc8147a9ac6906cc4e2c499c1681fb84320cbea899718fe2146b957cd292c373c;
    uint256 internal constant POSEIDON_T3_12 =
        7_853_200_120_776_062_878_684_798_364_095_072_458_815_029_376_092_732_009_249_414_926_327_459_813_530;
    bytes32 internal constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 internal constant ASP_POSTMAN = keccak256("ASP_POSTMAN");
    string internal constant FIXTURE = "test/private/fixtures/privacy-pools-v1.3.0.json";
    string internal constant CID = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG";
    bytes32 internal constant DEPOSITED = keccak256("Deposited(address,uint256,uint256,uint256,uint256)");
    uint256 internal constant MIN_DEPOSIT = 1e18;
    uint256 internal constant DEPOSIT = 5000e18;
    /// @dev Each token's cap through the router (raw USDG), as step 5b sets it.
    uint128 internal constant CAP = 50_000e6;

    IEntrypointRelease internal entrypoint;
    address internal withdrawalVerifier;
    address internal ragequitVerifier;
    mapping(address token => address) internal poolOf;
    mapping(address token => uint256[]) internal leavesOf;
    address internal releaseAdmin = makeAddr("release-admin");
    address internal postman = makeAddr("screener-postman");
    address internal depositor = makeAddr("depositor");
    uint256 internal asks;

    function setUp() public override {
        string memory url = vm.envOr("PRIVATE_LANE_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        require(
            _startsWith(url, "http://127.0.0.1:") || _startsWith(url, "http://localhost:"),
            "PRIVATE_LANE_FORK_URL is the read-only relay, a loopback URL"
        );
        vm.createSelectFork(url);
        assertEq(block.chainid, 4663, "Robinhood Chain mainnet");
        console2.log("4663 fork at block", block.number);
        // The Intent core fixture, on the fork; then the two tokens admitted and classified as the release does.
        super.setUp();
        _admit(CASHCAT, IntentCategory.MEME);
        _admit(PONS, IntentCategory.RH_ECOSYSTEM);
        _ecosystemVaults();
        _deployPrivacyPools();
        _deployRouterAsReleased();
    }

    // ---------------------------------------------------------------- the release's steps

    function _admit(address token, IntentCategory category) internal {
        vm.prank(safe);
        registry.setERC20Allowed(token, true, Lane.MEME, 1e18, 1_000_000e18, 10_000_000e18);
        partnerFactory.assignCategory(token, category);
        _modeled(token, COST_BPS);
    }

    /// @dev Two strategies of the Robinhood ecosystem universe that fund both tokens, in the plans' address order.
    function _ecosystemVaults() internal {
        mandate.categoryWeights = [uint16(0), 10_000, 10_000, 0];
        mandate.assets = new address[](2);
        mandate.assets[0] = CASHCAT;
        mandate.assets[1] = PONS;
        IntentVault a = _vault(1000, 2);
        IntentVault b = _vault(1500, 3);
        (first, second) = address(a) < address(b) ? (a, b) : (b, a);
    }

    function _create(bytes memory code) internal returns (address at) {
        assembly {
            at := create(0, add(code, 0x20), mload(code))
        }
        require(at != address(0) && at.code.length > 0, "deployment failed");
    }

    /// @dev deployPrivacyPools: the pinned build, the canonical libraries already on 4663, the release admin as the
    /// Entrypoint's first owner, a pool per token at fees 0/0, then OWNER_ROLE to the Safe and the admin's renounced.
    function _deployPrivacyPools() internal {
        assertEq(POSEIDON_T3.codehash, POSEIDON_T3_CODE, "the canonical PoseidonT3 is on 4663");
        assertEq(POSEIDON_T4.codehash, POSEIDON_T4_CODE, "the canonical PoseidonT4 is on 4663");
        assertEq(IPoseidon(POSEIDON_T3).hash([uint256(1), 2]), POSEIDON_T3_12, "PoseidonT3 computes Poseidon");
        string memory json = vm.readFile(FIXTURE);
        withdrawalVerifier = _create(vm.parseJsonBytes(json, ".creation.WithdrawalVerifier"));
        ragequitVerifier = _create(vm.parseJsonBytes(json, ".creation.CommitmentVerifier"));
        address implementation = _create(vm.parseJsonBytes(json, ".creation.Entrypoint"));
        bytes memory init = abi.encodeCall(IEntrypointRelease.initialize, (releaseAdmin, postman));
        entrypoint = IEntrypointRelease(
            _create(
                abi.encodePacked(vm.parseJsonBytes(json, ".creation.ERC1967Proxy"), abi.encode(implementation, init))
            )
        );
        bytes memory poolCode = vm.parseJsonBytes(json, ".creation.PrivacyPoolComplex");
        address[2] memory tokens = [CASHCAT, PONS];
        for (uint256 i; i < tokens.length; ++i) {
            poolOf[tokens[i]] = _create(
                abi.encodePacked(
                    poolCode, abi.encode(address(entrypoint), withdrawalVerifier, ragequitVerifier, tokens[i])
                )
            );
        }
        // The runtimes the pins name (scripts/lib/privacy-pools.mjs RUNTIME_SIZE); their bytes are checked by the release.
        assertEq(withdrawalVerifier.code.length, 1947, "WithdrawalVerifier runtime");
        assertEq(ragequitVerifier.code.length, 1582, "CommitmentVerifier runtime");
        assertEq(implementation.code.length, 13_490, "Entrypoint runtime");
        assertEq(address(entrypoint).code.length, 122, "ERC1967Proxy runtime");
        assertEq(poolOf[CASHCAT].code.length, 7720, "PrivacyPoolComplex runtime");
        vm.startPrank(releaseAdmin);
        for (uint256 i; i < tokens.length; ++i) {
            entrypoint.registerPool(tokens[i], poolOf[tokens[i]], MIN_DEPOSIT, 0, 0);
        }
        entrypoint.grantRole(OWNER_ROLE, MAINNET_SAFE);
        entrypoint.renounceRole(OWNER_ROLE, releaseAdmin);
        vm.stopPrank();
    }

    /// @dev deployPrivateRouter, then batch 01 (the Safe accepts it) and batch 02 (step 5b: the registry's entry router,
    /// the factory's filler, the caps), each by its owner.
    function _deployRouterAsReleased() internal {
        lane = new PrivateBorrowRouter(
            fills, IPrivacyPoolsEntrypoint(address(entrypoint)), vm.addr(ATTESTER_KEY), releaseAdmin
        );
        assertEq(lane.tokenCap(CASHCAT), 0, "deployed closed");
        assertEq(lane.tokenCap(PONS), 0, "deployed closed");
        vm.prank(releaseAdmin);
        lane.transferOwnership(MAINNET_SAFE);
        vm.prank(MAINNET_SAFE);
        lane.acceptOwnership();
        vm.prank(safe);
        registry.setRouter(address(lane), true);
        partnerFactory.setFiller(address(lane), true);
    }

    function _openCaps() internal {
        vm.startPrank(MAINNET_SAFE);
        lane.setTokenCap(CASHCAT, CAP);
        lane.setTokenCap(PONS, CAP);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- deposits, roots, proofs

    function _deposit(address token, uint256 nullifier, uint256 secret) internal returns (Note memory n) {
        uint256 precommitment = IPoseidon(POSEIDON_T3).hash([nullifier, secret]);
        deal(token, depositor, DEPOSIT);
        vm.prank(depositor);
        IERC20(token).approve(address(entrypoint), DEPOSIT);
        uint256 before = IERC20(token).balanceOf(poolOf[token]);
        vm.recordLogs();
        vm.prank(depositor);
        uint256 commitment = entrypoint.deposit(token, DEPOSIT, precommitment);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != poolOf[token] || logs[i].topics[0] != DEPOSITED) continue;
            (uint256 inserted, uint256 label,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertEq(inserted, commitment, "the pool's commitment");
            n = Note(DEPOSIT, label, nullifier, secret);
        }
        assertGt(n.label, 0, "the pool labelled the deposit");
        assertEq(IERC20(token).balanceOf(poolOf[token]) - before, DEPOSIT, "the token moved exactly into the pool");
        leavesOf[token].push(commitment);
    }

    function _decimals(uint256[] memory xs) internal pure returns (string[] memory out) {
        out = new string[](xs.length);
        for (uint256 i; i < xs.length; ++i) {
            out[i] = vm.toString(xs[i]);
        }
    }

    /// @dev A real proof spending `amount` of `n` for the router, committing to `t`, against the association set of
    /// `n` alone; returns that set's root, which the screener's postman then posts.
    function _prove(address token, Note memory n, uint256 amount, PrivateBorrowRouter.Terms memory t)
        internal
        returns (uint256 aspRoot, IPrivacyPool.WithdrawProof memory proof)
    {
        uint256[] memory approved = new uint256[](1);
        approved[0] = n.label;
        string memory o = string.concat("fork-ask", vm.toString(++asks));
        vm.serializeString(o, "scope", vm.toString(IPoolView(poolOf[token]).SCOPE()));
        vm.serializeString(o, "leaves", _decimals(leavesOf[token]));
        vm.serializeString(o, "labels", _decimals(approved));
        vm.serializeString(o, "value", vm.toString(n.value));
        vm.serializeString(o, "label", vm.toString(n.label));
        vm.serializeString(o, "nullifier", vm.toString(n.nullifier));
        vm.serializeString(o, "secret", vm.toString(n.secret));
        vm.serializeString(o, "amount", vm.toString(amount));
        vm.serializeString(o, "processooor", vm.toString(address(lane)));
        vm.serializeString(o, "data", vm.toString(abi.encode(t)));
        vm.serializeString(o, "newNullifier", vm.toString(n.nullifier + 1_000_003));
        string memory ask = vm.serializeString(o, "newSecret", vm.toString(n.secret + 1_000_033));
        string[] memory cmd = new string[](3);
        cmd[0] = "../web/node_modules/.bin/tsx";
        cmd[1] = "../web/scripts/private-prove.ts";
        cmd[2] = vm.toString(bytes(ask));
        (aspRoot,, proof) = abi.decode(vm.ffi(cmd), (uint256, uint256, IPrivacyPool.WithdrawProof));
    }

    /// @dev What the app hands the relayer: the proof, the terms it binds, the screener's attestation of `root` for
    /// `token` and the plan the rates service signs ahead of the listing.
    function _args(
        address token,
        IPrivacyPool.WithdrawProof memory proof,
        PrivateBorrowRouter.Terms memory t,
        uint256 root
    ) internal view returns (Args memory a) {
        uint40 at = uint40(block.timestamp);
        a.pool = poolOf[token];
        a.proof = proof;
        a.terms = t;
        a.attestation = _attestWith(ATTESTER_KEY, address(lane), block.chainid, root, token, at, at + 2 minutes);
        a.plan = _planAhead(core.loanCount() + 1, token, proof.pubSignals[2], t.principal, t.cap, 2, 2);
        a.signature = _sign(a.plan);
    }

    /// @dev The relayer sends the borrow.
    function _send(Args memory a) internal returns (uint256) {
        uint256[] memory limits = _shares(a.plan.allocations.length);
        vm.prank(relayer);
        return lane.borrow(IPrivacyPool(a.pool), a.proof, a.terms, a.attestation, a.plan, a.signature, limits);
    }

    // ---------------------------------------------------------------- tests

    /// @dev The Entrypoint as the release leaves it: the Safe owns it alone, the postman posts roots, each pool is
    /// registered for its token at the profile's minimum and fees 0/0, and the release admin holds nothing.
    function test_MainnetFork_TheEntrypointIsTheSafesAndEachPoolItsTokens() public {
        assertTrue(entrypoint.hasRole(OWNER_ROLE, MAINNET_SAFE), "the Safe owns the Entrypoint");
        assertFalse(entrypoint.hasRole(OWNER_ROLE, releaseAdmin), "the release admin renounced");
        assertTrue(entrypoint.hasRole(ASP_POSTMAN, postman), "the screener's postman posts roots");
        address[2] memory tokens = [CASHCAT, PONS];
        for (uint256 i; i < tokens.length; ++i) {
            (address pool, uint256 minimum, uint256 vetting, uint256 relay) = entrypoint.assetConfig(tokens[i]);
            assertEq(pool, poolOf[tokens[i]], "registered");
            assertEq(IPoolView(pool).ASSET(), tokens[i], "the pool's asset");
            assertEq(minimum, MIN_DEPOSIT, "the profile's minimum deposit");
            assertEq(vetting + relay, 0, "fees 0/0");
        }
        vm.prank(releaseAdmin);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", releaseAdmin, OWNER_ROLE)
        );
        entrypoint.registerPool(address(usdg), poolOf[CASHCAT], 1, 0, 0);
        vm.prank(releaseAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, releaseAdmin));
        lane.setTokenCap(CASHCAT, CAP);
        assertEq(lane.owner(), MAINNET_SAFE, "the Safe owns the router");
    }

    /// @dev A real CASHCAT deposit, the screener's root, a relayed borrow with a real proof, and the cap freed by
    /// `release` once the loan is repaid. Before step 5b sets the caps, the same borrow is refused.
    function test_MainnetFork_AMemecoinDepositBorrowsPrivatelyAndReleaseFreesTheCap() public {
        Note memory n = _deposit(CASHCAT, 61, 62);
        PrivateBorrowRouter.Terms memory t = _terms(uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP));
        (uint256 root, IPrivacyPool.WithdrawProof memory proof) = _prove(CASHCAT, n, COLLATERAL, t);
        vm.prank(postman);
        entrypoint.updateRoot(root, CID);
        assertEq(entrypoint.latestRoot(), root, "the screener's root");

        Args memory closed = _args(CASHCAT, proof, t, root);
        vm.expectRevert(PrivateBorrowRouter.TokenClosed.selector);
        _send(closed);
        _openCaps();

        uint256 poolBefore = IERC20(CASHCAT).balanceOf(poolOf[CASHCAT]);
        uint256 id = _send(_args(CASHCAT, proof, t, root));
        V2Loan memory l = core.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "funded by the partner vaults");
        assertEq(l.originator, fresh, "the proof's borrower");
        assertEq(l.token, CASHCAT, "a CASHCAT loan");
        assertEq(l.collateral, COLLATERAL, "the withdrawn piece is the collateral");
        assertEq(IERC20(CASHCAT).balanceOf(l.account), COLLATERAL, "escrowed exactly");
        assertEq(poolBefore - IERC20(CASHCAT).balanceOf(poolOf[CASHCAT]), COLLATERAL, "it left the pool");
        assertEq(IERC20(CASHCAT).balanceOf(address(lane)), 0, "the router holds no collateral");
        assertEq(usdg.balanceOf(address(lane)), 0, "nor USDG");
        assertEq(core.cashCredit(relayer), 0, "the relayer gets nothing");
        assertTrue(IPoolView(poolOf[CASHCAT]).nullifierHashes(proof.pubSignals[1]), "the note is spent");
        assertEq(lane.openPrincipal(CASHCAT), REVIEW_PRINCIPAL, "the principal counts against the cap");

        lane.release(_ids(id));
        assertEq(lane.openPrincipal(CASHCAT), REVIEW_PRINCIPAL, "an active loan keeps its place");

        usdg.mint(fresh, REVIEW_CAP);
        vm.startPrank(fresh);
        usdg.approve(address(core), REVIEW_CAP);
        core.reclaim(id, fresh);
        vm.stopPrank();
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.REPAID), "repaid");

        vm.expectEmit(true, true, false, true, address(lane));
        emit PrivateBorrowRouter.Released(id, CASHCAT, uint128(REVIEW_PRINCIPAL));
        lane.release(_ids(id));
        assertEq(lane.openPrincipal(CASHCAT), 0, "the cap is free again");
        vm.recordLogs();
        lane.release(_ids(id));
        assertEq(vm.getRecordedLogs().length, 0, "a second release does nothing");
    }

    /// @dev The same lane for an ecosystem token: PONS's own pool, root and proof.
    function test_MainnetFork_AnEcosystemTokenBorrowsThroughItsOwnPool() public {
        _openCaps();
        Note memory n = _deposit(PONS, 71, 72);
        PrivateBorrowRouter.Terms memory t = _terms(uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP));
        (uint256 root, IPrivacyPool.WithdrawProof memory proof) = _prove(PONS, n, COLLATERAL, t);
        vm.prank(postman);
        entrypoint.updateRoot(root, CID);
        uint256 id = _send(_args(PONS, proof, t, root));
        assertEq(core.getLoan(id).token, PONS, "a PONS loan");
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE), "funded");
        assertEq(lane.openPrincipal(PONS), REVIEW_PRINCIPAL, "PONS's cap only");
        assertEq(lane.openPrincipal(CASHCAT), 0, "CASHCAT's untouched");
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}

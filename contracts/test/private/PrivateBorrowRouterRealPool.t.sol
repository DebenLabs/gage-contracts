// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {PrivateLaneBaseTest} from "./PrivateLaneBase.t.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {PrivateBorrowRouter} from "../../src/private/PrivateBorrowRouter.sol";
import {IPrivacyPool} from "../../src/private/IPrivacyPools.sol";
import {MockQuirkERC20} from "../mocks/MockQuirkERC20.sol";

/// @dev The Privacy Pools v1.3.0 calls this suite makes beyond the ones the router uses.
interface IPrivacyPoolsAdmin {
    function registerPool(
        address asset,
        address pool,
        uint256 minimumDepositAmount,
        uint256 vettingFeeBPS,
        uint256 maxRelayFeeBPS
    ) external;
    function deposit(address asset, uint256 value, uint256 precommitment) external returns (uint256 commitment);
    function updateRoot(uint256 root, string memory ipfsCID) external returns (uint256 index);
    function latestRoot() external view returns (uint256);
}

interface IPrivacyPoolView {
    function SCOPE() external view returns (uint256);
    function nullifierHashes(uint256 nullifierHash) external view returns (bool);
    function currentTreeSize() external view returns (uint256);
}

interface IPoseidonT3 {
    function hash(uint256[2] memory input) external pure returns (uint256);
}

/// @notice Anything that answers to `withdraw`, as a team could deploy to push its own tokens: never called.
contract LookalikePool {
    function withdraw(IPrivacyPool.Withdrawal memory, IPrivacyPool.WithdrawProof memory) external {}
}

/// @notice The router against 0xbow's Privacy Pools v1.3.0 as the testnet runs it: the verified build from
/// fixtures/privacy-pools-v1.3.0.json (scripts/privacy-pools-fixture.mjs, every runtime hashed against the pinned build),
/// and real Groth16 proofs made by the app's own builder and snarkjs over the circuit files 0xbow's SDK pins
/// (web/scripts/private-prove.ts, through ffi). Opt in with PRIVATE_REAL_POOL=true and FOUNDRY_FFI=true; the circuit
/// files come from PRIVACY_POOLS_CIRCUITS or web/.cache/privacy-pools-circuits (`pnpm --filter ./web circuits`).
contract PrivateBorrowRouterRealPoolTest is PrivateLaneBaseTest {
    struct Note {
        uint256 value;
        uint256 label;
        uint256 commitment;
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

    string internal constant FIXTURE = "test/private/fixtures/privacy-pools-v1.3.0.json";
    address internal constant POSEIDON_T3 = 0x3333333C0A88F9BE4fd23ed0536F9B6c427e3B93;
    address internal constant POSEIDON_T4 = 0x4443338EF595F44e0121df4C21102677B142ECF0;
    uint256 internal constant POSEIDON_T3_12 =
        7_853_200_120_776_062_878_684_798_364_095_072_458_815_029_376_092_732_009_249_414_926_327_459_813_530;
    string internal constant CID = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG";
    uint256 internal constant DEPOSIT = 500e18;
    bytes32 internal constant DEPOSITED = keccak256("Deposited(address,uint256,uint256,uint256,uint256)");
    bytes4 internal constant CONTEXT_MISMATCH = bytes4(keccak256("ContextMismatch()"));
    bytes4 internal constant INCORRECT_ASP_ROOT = bytes4(keccak256("IncorrectASPRoot()"));
    bytes4 internal constant INVALID_PROOF = bytes4(keccak256("InvalidProof()"));

    IPrivacyPoolsAdmin internal entrypoint;
    address internal pool;
    address internal withdrawalVerifier;
    address internal ragequitVerifier;
    address internal postman = makeAddr("postman");
    address internal depositor = makeAddr("depositor");
    uint256[] internal leaves;
    uint256 internal asks;

    function setUp() public override {
        if (!vm.envOr("PRIVATE_REAL_POOL", false)) {
            vm.skip(true);
            return;
        }
        super.setUp();
        _deployPrivacyPools();
        _deployLane(address(entrypoint));
    }

    // ---------------------------------------------------------------- the verified build

    function _create(bytes memory code) internal returns (address at) {
        assembly {
            at := create(0, add(code, 0x20), mload(code))
        }
        require(at != address(0) && at.code.length > 0, "deployment failed");
    }

    function _newPool(address asset) internal returns (address) {
        bytes memory code = vm.parseJsonBytes(vm.readFile(FIXTURE), ".creation.PrivacyPoolComplex");
        return
            _create(
                abi.encodePacked(code, abi.encode(address(entrypoint), withdrawalVerifier, ragequitVerifier, asset))
            );
    }

    function _deployPrivacyPools() internal {
        string memory json = vm.readFile(FIXTURE);
        vm.etch(POSEIDON_T3, vm.parseJsonBytes(json, ".runtime.PoseidonT3"));
        vm.etch(POSEIDON_T4, vm.parseJsonBytes(json, ".runtime.PoseidonT4"));
        assertEq(IPoseidonT3(POSEIDON_T3).hash([uint256(1), 2]), POSEIDON_T3_12, "PoseidonT3 computes Poseidon");
        withdrawalVerifier = _create(vm.parseJsonBytes(json, ".creation.WithdrawalVerifier"));
        ragequitVerifier = _create(vm.parseJsonBytes(json, ".creation.CommitmentVerifier"));
        address implementation = _create(vm.parseJsonBytes(json, ".creation.Entrypoint"));
        bytes memory init = abi.encodeWithSignature("initialize(address,address)", address(this), postman);
        bytes memory proxy = vm.parseJsonBytes(json, ".creation.ERC1967Proxy");
        entrypoint = IPrivacyPoolsAdmin(_create(abi.encodePacked(proxy, abi.encode(implementation, init))));
        pool = _newPool(address(nvda));
        entrypoint.registerPool(address(nvda), pool, 1e18, 0, 0);
    }

    // ---------------------------------------------------------------- deposits, roots, proofs

    function _deposit(uint256 nullifier, uint256 secret) internal returns (Note memory n) {
        uint256 precommitment = IPoseidonT3(POSEIDON_T3).hash([nullifier, secret]);
        nvda.mint(depositor, DEPOSIT);
        vm.prank(depositor);
        nvda.approve(address(entrypoint), DEPOSIT);
        vm.recordLogs();
        vm.prank(depositor);
        uint256 commitment = entrypoint.deposit(address(nvda), DEPOSIT, precommitment);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != pool || logs[i].topics[0] != DEPOSITED) continue;
            (uint256 inserted, uint256 label,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertEq(inserted, commitment, "the pool's commitment");
            n = Note(DEPOSIT, label, commitment, nullifier, secret);
        }
        assertGt(n.label, 0, "the pool labelled the deposit");
        leaves.push(commitment);
    }

    /// @dev The screener posting an association-set root.
    function _post(uint256 root) internal {
        vm.prank(postman);
        entrypoint.updateRoot(root, CID);
    }

    function _labels(uint256 a) internal pure returns (uint256[] memory xs) {
        xs = new uint256[](1);
        xs[0] = a;
    }

    function _labels(uint256 a, uint256 b) internal pure returns (uint256[] memory xs) {
        xs = new uint256[](2);
        xs[0] = a;
        xs[1] = b;
    }

    function _decimals(uint256[] memory xs) internal pure returns (string[] memory out) {
        out = new string[](xs.length);
        for (uint256 i; i < xs.length; ++i) {
            out[i] = vm.toString(xs[i]);
        }
    }

    /// @dev A real proof that spends `amount` of `n` for the router, committing to `t`, against the association set
    /// `approved`; also returns that set's root, which the screener then posts.
    function _prove(Note memory n, uint256[] memory approved, uint256 amount, PrivateBorrowRouter.Terms memory t)
        internal
        returns (uint256 aspRoot, IPrivacyPool.WithdrawProof memory proof)
    {
        string memory o = string.concat("ask", vm.toString(++asks));
        vm.serializeString(o, "scope", vm.toString(IPrivacyPoolView(pool).SCOPE()));
        vm.serializeString(o, "leaves", _decimals(leaves));
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

    function _args(IPrivacyPool.WithdrawProof memory proof, PrivateBorrowRouter.Terms memory t, uint256 root)
        internal
        view
        returns (Args memory a)
    {
        a.pool = pool;
        a.proof = proof;
        a.terms = t;
        a.attestation = _attest(root);
        a.plan = _planAhead(core.loanCount() + 1, address(nvda), proof.pubSignals[2], t.principal, t.cap, 2, 2);
        a.signature = _sign(a.plan);
    }

    function _send(address from, Args memory a) internal returns (uint256) {
        uint256[] memory limits = _shares(a.plan.allocations.length);
        vm.prank(from);
        return lane.borrow(IPrivacyPool(a.pool), a.proof, a.terms, a.attestation, a.plan, a.signature, limits);
    }

    function _review() internal view returns (PrivateBorrowRouter.Terms memory) {
        return _terms(uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP));
    }

    // ---------------------------------------------------------------- tests

    /// @dev Relayer submission, the borrower and terms the proof binds, the exact amount received, and the router's
    /// balances left as they were.
    function test_RealPool_ARelayerBorrowsExactlyTheWithdrawnPieceForTheProofsBorrower() public {
        Note memory n = _deposit(11, 12);
        PrivateBorrowRouter.Terms memory t = _review();
        (uint256 root, IPrivacyPool.WithdrawProof memory proof) = _prove(n, _labels(n.label), COLLATERAL, t);
        _post(root);
        nvda.mint(address(lane), 3e18);
        usdg.mint(address(lane), 7e6);

        uint256 id = _send(relayer, _args(proof, t, root));

        V2Loan memory l = core.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "funded by the partner vaults");
        assertEq(l.originator, fresh, "the proof's borrower");
        assertEq(core.ownerOf(id), fresh, "the right goes to the borrower");
        assertEq(core.cashCredit(fresh), l.principal - l.originationFee, "and the cash");
        assertEq(core.cashCredit(relayer), 0, "the relayer gets no cash");
        assertEq(nvda.balanceOf(relayer), 0, "nor collateral");
        assertEq(l.collateral, COLLATERAL, "the withdrawn piece is the collateral");
        assertEq(nvda.balanceOf(l.account), COLLATERAL, "escrowed exactly");
        assertEq(nvda.balanceOf(pool), DEPOSIT - COLLATERAL, "it left the pool");
        assertEq(nvda.balanceOf(address(lane)), 3e18, "the router's collateral balance is unchanged");
        assertEq(usdg.balanceOf(address(lane)), 7e6, "and its USDG balance");
        assertTrue(IPrivacyPoolView(pool).nullifierHashes(proof.pubSignals[1]), "the note is spent");
        assertEq(IPrivacyPoolView(pool).currentTreeSize(), 2, "the change note joined the tree");
    }

    function test_RealPool_RefusesTermsTheProofDidNotBind() public {
        Note memory n = _deposit(21, 22);
        PrivateBorrowRouter.Terms memory t = _review();
        (uint256 root, IPrivacyPool.WithdrawProof memory proof) = _prove(n, _labels(n.label), COLLATERAL, t);
        _post(root);

        PrivateBorrowRouter.Terms memory stolen = _review();
        stolen.borrower = relayer;
        Args memory a = _args(proof, stolen, root);
        vm.expectRevert(CONTEXT_MISMATCH);
        _send(relayer, a);

        PrivateBorrowRouter.Terms memory dearer = _terms(uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP) + 1);
        a = _args(proof, dearer, root);
        vm.expectRevert(CONTEXT_MISMATCH);
        _send(relayer, a);

        uint256 id = _send(relayer, _args(proof, t, root));
        assertEq(core.getLoan(id).originator, fresh, "the proof still works for the terms it binds");
    }

    function test_RealPool_RefusesAPoolTheEntrypointDoesNotRegister() public {
        _post(1);
        IPrivacyPool.WithdrawProof memory nothing;
        address team = makeAddr("team-wallet");
        nvda.mint(team, COLLATERAL);

        Args memory a = _args(nothing, _review(), 1);
        a.pool = _newPool(address(nvda));
        vm.expectRevert(PrivateBorrowRouter.UnknownPool.selector);
        _send(team, a);

        a.pool = address(new LookalikePool());
        vm.expectRevert(PrivateBorrowRouter.UnknownPool.selector);
        _send(team, a);
        assertEq(nvda.balanceOf(team), COLLATERAL, "nothing moved");
    }

    function test_RealPool_RefusesARevokedDeposit() public {
        Note memory kept = _deposit(31, 32);
        Note memory dropped = _deposit(33, 34);
        PrivateBorrowRouter.Terms memory t = _review();
        (uint256 root, IPrivacyPool.WithdrawProof memory proof) =
            _prove(dropped, _labels(kept.label, dropped.label), COLLATERAL, t);
        _post(root);
        // The screener revokes `dropped`: the set is `kept` alone, whose one-leaf root is the label itself.
        _post(kept.label);

        Args memory stale = _args(proof, t, root);
        vm.expectRevert(PrivateBorrowRouter.AttestationRootMismatch.selector);
        _send(fresh, stale);

        Args memory current = _args(proof, t, kept.label);
        vm.expectRevert(PrivateBorrowRouter.AttestationRootMismatch.selector);
        _send(fresh, current);

        // The pool refuses the stale root itself, whoever relays the proof.
        vm.prank(address(lane));
        vm.expectRevert(INCORRECT_ASP_ROOT);
        IPrivacyPool(pool).withdraw(IPrivacyPool.Withdrawal(address(lane), abi.encode(t)), proof);
        assertFalse(IPrivacyPoolView(pool).nullifierHashes(proof.pubSignals[1]), "the note is not spent");
    }

    /// @dev A wallet that holds the token but no note has no proof to offer: an altered one fails verification.
    function test_RealPool_WithoutAValidProofNothingMoves() public {
        Note memory n = _deposit(41, 42);
        PrivateBorrowRouter.Terms memory t = _review();
        (uint256 root, IPrivacyPool.WithdrawProof memory proof) = _prove(n, _labels(n.label), COLLATERAL, t);
        _post(root);
        address team = makeAddr("team-wallet");
        nvda.mint(team, COLLATERAL);
        vm.prank(team);
        nvda.approve(address(lane), type(uint256).max);

        proof.pubSignals[2] = 2 * COLLATERAL;
        Args memory a = _args(proof, t, root);
        vm.expectRevert(INVALID_PROOF);
        _send(team, a);
        assertEq(nvda.balanceOf(team), COLLATERAL, "the caller keeps its tokens");
        assertEq(nvda.balanceOf(pool), DEPOSIT, "the pool keeps the deposit");
    }

    function test_RealPool_RefusesATaxedFirstLeg() public {
        Note memory n = _deposit(51, 52);
        PrivateBorrowRouter.Terms memory t = _review();
        (uint256 root, IPrivacyPool.WithdrawProof memory proof) = _prove(n, _labels(n.label), COLLATERAL, t);
        _post(root);
        vm.etch(address(nvda), address(new MockQuirkERC20("NVDA", "NVDA", 18)).code);
        MockQuirkERC20(address(nvda)).setQuirk(address(lane), MockQuirkERC20.Quirk.INTO_TAX);

        Args memory a = _args(proof, t, root);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrivateBorrowRouter.InexactTransfer.selector, COLLATERAL, COLLATERAL - COLLATERAL / 100
            )
        );
        _send(fresh, a);
        assertFalse(IPrivacyPoolView(pool).nullifierHashes(proof.pubSignals[1]), "the note is not spent");
    }
}

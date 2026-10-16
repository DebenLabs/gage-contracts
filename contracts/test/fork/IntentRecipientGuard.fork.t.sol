// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";

/// @notice The S7 recipient guard against the contracts it exists for: on a local fork of each chain, a factory accepts
/// that chain's real `DealFeeRouter` as protocol recipient and refuses its real `FeeFloor`, its `FeeSink` and a wallet.
/// Addresses are the published manifests': on testnet the frozen generation's core, reserve, lens, grades and protocol
/// recipient (`launch/staging/staging-freeze-r1-20260925.publication.json`) with the `FeeFloor` and `FeeSink` of
/// `launch/live/46630.json`; on mainnet `launch/live/4663.json`, which publishes no reserve lens.
/// Set `INTENT_GUARD_FORK_URL` to the chain's public node; nothing is sent anywhere. Skips itself when unset.
/// `INTENT_GUARD_FORK_BLOCK` optionally pins a recent block (the public nodes prune older state); unset, it is the head.
contract IntentRecipientGuardForkTest is Test {
    struct Route {
        address core;
        address reserve;
        address lens;
        address grades;
        address processor;
        address floor;
        address sink;
    }

    function _route() internal view returns (Route memory r) {
        if (block.chainid == 46_630) {
            r = Route({
                core: 0xd3Ee90E66366B0b83282E908bAaB0AdF55b3A957,
                reserve: 0x23f70efcD18c83Daf442563f2B189Fa39c471Db6,
                lens: 0xB00B46A450f1A972a4f83ecbE27fE19b270E56BF,
                grades: 0xCe54fB35E34f0D53d930255B80fBf8F3b71adaC7,
                processor: 0x15ff6F47076306E03aF8315BECf6137298D28446,
                floor: 0xc0DDA77ed245Ce78B7A8E7506c4cBcaE1a2A87e4,
                sink: 0x962C31eeEB4e83b6dafcB30fbB47dd09Adb17A5D
            });
        } else if (block.chainid == 4663) {
            r = Route({
                core: MAINNET_CORE,
                reserve: MAINNET_RESERVE,
                lens: address(0),
                grades: MAINNET_GRADES,
                processor: MAINNET_PROCESSOR,
                floor: MAINNET_FLOOR,
                sink: MAINNET_SINK
            });
        } else {
            revert("unknown chain");
        }
    }

    address internal constant MAINNET_CORE = 0xfee799ade96229C2c128BC5ed9E55F8D9d01A7E9;
    address internal constant MAINNET_RESERVE = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    address internal constant MAINNET_GRADES = 0x0250ADfA79Ab2E303AF4C434c62F92f55DD38e50;
    address internal constant MAINNET_PROCESSOR = 0xEaE95cD11e1105BF1E82033c918ff17f931B0245;
    address internal constant MAINNET_FLOOR = 0x042fed6722e57093D97a4527ad622472ccC8A7be;
    address internal constant MAINNET_SINK = 0xbE2066a95CF3eCc28c9665E5B024C3f8A313E19F;

    /// @dev The strategy code's two data contracts, written once outside any expected revert.
    address private _chunkA;
    address private _chunkB;

    function _writeCode() internal {
        IntentVaultCode store = new IntentVaultCode();
        _chunkA = store.CHUNK_A();
        _chunkB = store.CHUNK_B();
    }

    /// @dev The factory's creation is the only external call here, so an armed `expectRevert` binds to it. The code's
    /// two data contracts are written once by the caller beforehand (`_writeCode`): created in here, they would be the
    /// call the expectation takes.
    function _factory(Route memory r, address recipient) internal returns (IntentFactory) {
        return new IntentFactory(
            IntentFactory.Params({
                core: r.core,
                reserve: r.reserve,
                reserveLens: r.lens,
                grades: r.grades,
                protocolRecipient: recipient,
                initialOwner: address(this),
                codeA: _chunkA,
                codeB: _chunkB
            })
        );
    }

    function testTheRealProcessorIsAcceptedAndTheRealFloorSinkAndAWalletAreRefused() public {
        string memory rpc = vm.envOr("INTENT_GUARD_FORK_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 blk = vm.envOr("INTENT_GUARD_FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        Route memory r = _route();
        // The named contracts are live, so each refusal below is the guard's verdict on real code, not on an empty
        // account.
        assertGt(r.core.code.length, 0, "core code");
        assertGt(r.processor.code.length, 0, "processor code");
        assertGt(r.floor.code.length, 0, "floor code");
        assertGt(r.sink.code.length, 0, "sink code");
        _writeCode();
        address[3] memory refused = [r.floor, r.sink, makeAddr("a wallet")];
        // The floor has no `USDG()` and the sink no `availableUSDG()`: each call reverts with no data. A wallet is
        // refused with NotAFeeProcessor.
        bytes[3] memory reasons =
            [bytes(""), bytes(""), abi.encodeWithSelector(IntentFactory.NotAFeeProcessor.selector)];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(reasons[i]);
            _factory(r, refused[i]);
        }
        IntentFactory factory = _factory(r, r.processor);
        assertEq(factory.protocolRecipient(), r.processor);
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(reasons[i]);
            factory.setProtocolRecipient(refused[i]);
        }
        factory.setProtocolRecipient(r.processor);
        emit log_named_uint("chain", block.chainid);
        emit log_named_uint("block", block.number);
        emit log_named_address("accepted processor", r.processor);
        emit log_named_address("refused floor", r.floor);
    }
}

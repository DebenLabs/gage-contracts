// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentCategory, IntentLimit} from "../../src/intent/IntentVaultState.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {IntentLimits} from "../helpers/IntentLimits.sol";

/// @notice The curator settings are the vault's first six storage slots (they were shared with the S9-01 settings
/// extension, now folded back into the vault). These cases pin that layout: each setting writes exactly the vault
/// slot it names and nothing else, the vault's getters read back what it wrote, and the rest of the vault's state
/// starts at slot 6. The risk limits are moved through the asset policy since v12 (D53), which applies them here; the
/// retired ceilings keep slots 2 and 3, so the layout is the same for every version.
contract IntentVaultSettingsLayoutTest is IntentAccountingBaseTest {
    uint256 internal constant GRADES_AND_CAP_SLOT = 0;
    uint256 internal constant WEIGHT_MAPPING_SLOT = 1;
    uint256 internal constant SWITCHES_SLOT = 4;
    uint256 internal constant LIMITS_SLOT = 5;
    uint256 internal constant FIRST_VAULT_SLOT = 6;
    /// @dev Where the vault keeps its side pockets (`forge inspect IntentVault storageLayout`).
    uint256 internal constant POCKETS_SLOT = 20;
    uint256 internal constant POCKET_CLAIMED_SLOT = 22;
    uint256 internal constant POCKET_LIABILITY_SLOT = 23;
    /// @dev `Pocket.claimed`: after loanId, token, amount and supply.
    uint256 internal constant CLAIMED_FIELD = 4;
    /// @dev `_openLoans._inner._values.length` (`forge inspect IntentVault storageLayout`): the count of open reward
    /// records every deposit, redeem and lender sale claims sGAGE for. No getter exposes it, so clients read this slot
    /// to size a checkpoint's gas limit: `INTENT_OPEN_RECORDS_SLOT` in shared/tx-gas.mjs must name the same slot.
    uint256 internal constant OPEN_LOANS_SLOT = 29;
    /// @dev `earliestMaturity`, the low 40 bits of the slot after the set's mapping: the packed neighbour that proves
    /// the set sits where `OPEN_LOANS_SLOT` says.
    uint256 internal constant EARLIEST_MATURITY_SLOT = 31;

    function _weightSlot(IntentCategory lane) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(uint8(lane)), WEIGHT_MAPPING_SLOT));
    }

    /// @dev Every storage slot of the vault the last recorded calls wrote.
    function _writes() internal returns (bytes32[] memory writes) {
        (, writes) = vm.accesses(address(partner));
    }

    function _assertOnlyWrote(bytes32 expected) internal {
        bytes32[] memory writes = _writes();
        assertGt(writes.length, 0, "the setting wrote the vault");
        for (uint256 i; i < writes.length; ++i) {
            assertEq(writes[i], expected, "a setting wrote a vault slot outside its own");
        }
    }

    function test_eachSettingWritesExactlyItsOwnVaultSlotAndTheVaultReadsItBack() public {
        vm.startPrank(curator);

        IntentAssetPolicy policy = partner.ASSET_POLICY();
        uint16 weight = partner.categoryWeightBps(IntentCategory.STOCK);
        vm.record();
        policy.setLimit(IntentLimits.category(IntentCategory.STOCK), weight);
        _assertOnlyWrote(_weightSlot(IntentCategory.STOCK));
        assertEq(partner.categoryWeightBps(IntentCategory.STOCK), weight);

        uint8 grade = partner.minGrade();
        vm.record();
        partner.setMinGrade(grade);
        _assertOnlyWrote(bytes32(GRADES_AND_CAP_SLOT));
        assertEq(partner.minGrade(), grade);

        uint8 rateGrade = partner.minRateGrade();
        vm.record();
        policy.setLimit(IntentLimit.MIN_RATE_GRADE, rateGrade);
        _assertOnlyWrote(bytes32(GRADES_AND_CAP_SLOT));
        assertEq(partner.minRateGrade(), rateGrade);

        vm.record();
        partner.setExecutionCap(1234);
        _assertOnlyWrote(bytes32(GRADES_AND_CAP_SLOT));
        assertEq(partner.executionCapBps(), 1234);

        vm.record();
        partner.setFeeRecipient(bob);
        _assertOnlyWrote(bytes32(SWITCHES_SLOT));
        assertEq(partner.feeRecipient(), bob);

        vm.record();
        partner.setPaused(true);
        _assertOnlyWrote(bytes32(SWITCHES_SLOT));
        assertTrue(partner.paused());
        partner.setPaused(false);

        bool open = partner.fillersOpen();
        vm.record();
        partner.setFillersOpen(!open);
        _assertOnlyWrote(bytes32(SWITCHES_SLOT));
        assertEq(partner.fillersOpen(), !open);
        partner.setFillersOpen(open);

        uint128 perLoan = partner.maxLoanPrincipal();
        uint16 perToken = partner.maxAssetBps();
        uint16 buffer = partner.bufferBps();
        IntentLimit[3] memory packed =
            [IntentLimit.MAX_LOAN_PRINCIPAL, IntentLimit.MAX_ASSET_BPS, IntentLimit.BUFFER_BPS];
        uint128[3] memory values = [perLoan, perToken, buffer];
        for (uint256 i; i < packed.length; ++i) {
            vm.record();
            policy.setLimit(packed[i], values[i]);
            _assertOnlyWrote(bytes32(LIMITS_SLOT));
        }
        assertEq(partner.maxLoanPrincipal(), perLoan);
        assertEq(partner.maxAssetBps(), perToken);
        assertEq(partner.bufferBps(), buffer);

        // An asset change is the asset policy's to record: the vault's storage is not written at all.
        vm.record();
        partner.setAsset(address(gold), false);
        (, bytes32[] memory writes) = vm.accesses(address(partner));
        assertEq(writes.length, 0, "an asset change writes no vault slot");
        assertFalse(partner.ASSET_POLICY().picked(address(gold)));

        vm.stopPrank();
    }

    function test_theSharedSlotsHoldWhatTheGettersReadAndTheVaultsOwnStateStartsAtSlotSix() public {
        vm.prank(curator);
        partner.setFeeRecipient(bob);
        bytes32 switches = vm.load(address(partner), bytes32(SWITCHES_SLOT));
        assertEq(address(uint160(uint256(switches))), partner.feeRecipient(), "feeRecipient is slot 4's low bytes");
        bytes32 packed = vm.load(address(partner), bytes32(GRADES_AND_CAP_SLOT));
        assertEq(uint8(uint256(packed)), partner.minGrade(), "minGrade is slot 0's first byte");
        assertEq(uint8(uint256(packed) >> 8), partner.minRateGrade(), "minRateGrade follows");
        assertEq(uint16(uint256(packed) >> 16), partner.executionCapBps(), "executionCapBps follows");
        _enter(alice, 10_000e6);
        assertGt(partner.totalSupply(), 0);
        assertEq(
            uint256(vm.load(address(partner), bytes32(FIRST_VAULT_SLOT))),
            partner.totalSupply(),
            "the vault's own state begins right after the shared layout"
        );
    }

    function _openRecords() internal view returns (uint256) {
        return uint256(vm.load(address(partner), bytes32(OPEN_LOANS_SLOT)));
    }

    /// @dev The client gas rule (shared/tx-gas.mjs, chaos finding 1 of 26 September 2026) reads the open-record count
    /// from this slot; if the layout moves, the rule under-counts and deposits run out of gas again.
    function test_openRecordCountIsAtItsPinnedSlot() public {
        _enter(alice, 100_000e6);
        assertEq(_openRecords(), 0, "an empty book has no open record");
        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = _list(borrower, address(nvda), 1e18, 100e6, 110e6, T21);
            _route(ids[i], UNITS);
        }
        assertEq(_openRecords(), 3, "each reward-bearing loan opens one record");
        vm.warp(_startOf(ids[0]) + 3 days);
        _repay(ids[0]);
        partner.settle(_ids(ids[0]));
        partner.harvestRewards(_ids(ids[0]));
        assertEq(_openRecords(), 2, "a settled loan whose rewards are collected leaves the set");
        assertEq(
            uint40(uint256(vm.load(address(partner), bytes32(EARLIEST_MATURITY_SLOT)))),
            partner.earliestMaturity(),
            "earliestMaturity is the low 40 bits of the slot after the set"
        );
        assertLt(partner.earliestMaturity(), type(uint40).max, "the neighbour holds a live maturity, not its default");
    }

    /// @dev A claim writes the claimant's flag, the pocket's paid total and the liability for its token, and no other
    /// slot of the vault (D51).
    function test_aClaimWritesOnlyTheClaimsOwnSlots() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        _book(id);
        assertEq(partner.pocketCount(), 1);
        bytes32 claimed = bytes32(uint256(keccak256(abi.encode(uint256(1), POCKETS_SLOT))) + CLAIMED_FIELD);
        bytes32 flag = keccak256(abi.encode(alice, keccak256(abi.encode(uint256(1), POCKET_CLAIMED_SLOT))));
        bytes32 liability = keccak256(abi.encode(address(usdg), POCKET_LIABILITY_SLOT));
        uint256 owed = partner.pocketClaimable(1, alice);
        vm.record();
        vm.prank(alice);
        partner.claimPocket(1);
        bytes32[] memory writes = _writes();
        assertGt(writes.length, 0, "the claim wrote the vault");
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(
                writes[i] == claimed || writes[i] == flag || writes[i] == liability,
                "a claim wrote a slot outside its own"
            );
        }
        assertEq(uint256(vm.load(address(partner), claimed)), owed, "the paid total is not where the layout says");
        assertEq(uint256(vm.load(address(partner), flag)), 1, "the claimant's flag is not where the layout says");
    }
}

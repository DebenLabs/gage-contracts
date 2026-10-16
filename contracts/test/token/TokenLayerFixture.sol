// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {BaseTest} from "../Base.t.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {SGAGE} from "../../src/token/SGAGE.sol";
import {Drip} from "../../src/token/Drip.sol";
import {Emissions} from "../../src/token/Emissions.sol";
import {LPHook} from "../../src/token/LPHook.sol";
import {LPRewards} from "../../src/token/LPRewards.sol";
import {SeedTimelock} from "../../src/token/SeedTimelock.sol";
import {ILPRewards} from "../../src/interfaces/token/ILPRewards.sol";
import {ISeedTimelock} from "../../src/interfaces/token/ISeedTimelock.sol";
import {IDrip} from "../../src/interfaces/token/IDrip.sol";
import {PositionMath} from "../../src/libraries/PositionMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRevertingLPRewards} from "../mocks/MockRevertingLPRewards.sol";

/// @notice The full token layer on a real Uniswap v4 deployment: Emissions, sGAGE, Drip, a mock GAGE, the mined
///         LPHook, the GAGE/sGAGE pool, LPRewards with the seed set, and SeedTimelock. Launched at setUp time.
abstract contract TokenLayerFixture is BaseTest, V4Fixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS = Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;

    Emissions internal emissions;
    SGAGE internal sgage;
    Drip internal drip;
    MockERC20 internal gage;
    LPHook internal hook;
    LPRewards internal lpRewards;
    SeedTimelock internal seedTimelock;
    PoolKey internal pool;
    address internal dealRewardsStub = makeAddr("dealRewards");
    address internal lp1;
    address internal lp2;
    uint256 internal seedId;

    /// @dev About 63,000 GAGE and 63M sGAGE at 1 GAGE = 1,000 sGAGE: deep enough for 1% impact bounds.
    uint128 internal constant SEED_LIQ = 2e24;
    uint128 internal constant LIQ1 = 4e20;
    uint128 internal constant LIQ2 = 1e20;

    function setUp() public virtual override {
        super.setUp();
        _deployV4();
        lp1 = borrower;
        lp2 = lender;

        emissions = new Emissions(safe, address(this));
        sgage = new SGAGE(address(emissions), treasury);
        drip = new Drip(sgage, address(this));
        gage = new MockERC20("GAGE", "GAGE", 18);

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), HOOK_FLAGS, type(LPHook).creationCode, abi.encode(poolManager, address(posm), address(this))
        );
        hook = new LPHook{salt: salt}(poolManager, address(posm), address(this));
        assertEq(address(hook), hookAddr, "mined address");

        // 1 GAGE = 1,000 sGAGE (the treasury bought 1M GAGE against the 1B seed)
        pool = _initPoolAtPriceWithFee(address(gage), 1e18, address(sgage), 1000e18, address(hook), 30_000);
        lpRewards = new LPRewards(sgage, drip, emissions, posm, address(hook), pool, address(this));
        hook.setLPRewards(lpRewards);
        emissions.wire(sgage, lpRewards, dealRewardsStub);
        drip.setGrantors(dealRewardsStub, address(lpRewards));
        seedTimelock = new SeedTimelock(posm, treasury);

        // balances and approvals
        address[3] memory who = [treasury, lp1, lp2];
        for (uint256 i = 0; i < who.length; ++i) {
            gage.mint(who[i], 10_000_000e18);
            if (who[i] != treasury) {
                vm.prank(treasury);
                sgage.transfer(who[i], 100_000_000e18);
            }
            _approvePosm(who[i], address(gage));
            _approvePosm(who[i], address(sgage));
        }
        seedId = _mintFullRange(pool, SEED_LIQ, treasury, treasury);
        lpRewards.setSeed(seedId);

        vm.prank(safe);
        emissions.launch(uint40(block.timestamp));
        vm.label(address(hook), "LPHook");
        vm.label(address(lpRewards), "LPRewards");
        vm.label(address(gage), "GAGE");
    }

    // ----------------------------------------------------------------- helpers

    function _rate0() internal view returns (uint256) {
        return emissions.liquidityBudget(0) / emissions.EPOCH();
    }

    function _expectedValue(uint256 tokenId) internal view returns (uint256 value) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(pool.toId());
        (, int24 lower, int24 upper) = _ticks(tokenId);
        (uint256 a0, uint256 a1) = PositionMath.amountsForLiquidity(
            sqrtP,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            posm.getPositionLiquidity(tokenId)
        );
        bool sgageIs0 = Currency.unwrap(pool.currency0) == address(sgage);
        if (sgageIs0) {
            value = a1 + Math.mulDiv(Math.mulDiv(a0, sqrtP, FixedPoint96.Q96), sqrtP, FixedPoint96.Q96);
        } else {
            value = a0 + Math.mulDiv(Math.mulDiv(a1, FixedPoint96.Q96, sqrtP), FixedPoint96.Q96, sqrtP);
        }
    }

    function _ticks(uint256 tokenId) internal view returns (bool, int24 lower, int24 upper) {
        (bool ok, bytes memory data) =
            address(posm).staticcall(abi.encodeWithSignature("positionInfo(uint256)", tokenId));
        require(ok);
        uint256 info = abi.decode(data, (uint256));
        lower = int24(int256(uint256((info >> 8) & 0xFFFFFF)));
        upper = int24(int256(uint256((info >> 32) & 0xFFFFFF)));
        return (true, lower, upper);
    }

    // ----------------------------------------------------------------- second hook helper

    /// @dev Mines a fresh salt that is different from `used` so a second hook lands at a second flagged address.
    function _deploySecondHook(bytes32 used) internal returns (LPHook h) {
        bytes memory creation =
            abi.encodePacked(type(LPHook).creationCode, abi.encode(poolManager, address(posm), address(this)));
        bytes32 salt = bytes32(uint256(used) + 1);
        for (uint256 i = 0; i < 200_000; ++i) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(creation)))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && predicted.code.length == 0) {
                h = new LPHook{salt: salt}(poolManager, address(posm), address(this));
                return h;
            }
            salt = bytes32(uint256(salt) + 1);
        }
        revert("no salt");
    }
}

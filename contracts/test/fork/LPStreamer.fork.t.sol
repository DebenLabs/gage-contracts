// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LPRewards} from "../../src/token/LPRewards.sol";
import {LPStreamer} from "../../src/token/LPStreamer.sol";
import {Emissions} from "../../src/token/Emissions.sol";

/// @notice The streamer deployed next to the live Robinhood Chain (4663) LPRewards (D64): real positions, real
///         accrual, one pot, one epoch, and the bounty report's one-block position next to them. The only direct
///         state writes are the test treasury's and the attacker's token balances.
/// @dev Env: GAGE_MAINNET_RPC (required, the suite skips itself otherwise), GAGE_FORK_BLOCK (optional, 0 or unset
///      for the latest block). Run: forge test --match-path test/fork/LPStreamer.fork.t.sol -vv
contract LPStreamerForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    // launch/live/4663.json
    address internal constant GAGE = 0x7163aE1B5AeA2f09EBc609C52b4dcAc0a7a4bC2d;
    address internal constant SGAGE = 0x78c88CF8F6E612955526cEB501be82BF3279Bd5d;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant LP_REWARDS = 0x57Ea11d7250C7Ee3127eFa9d0e2b114348C5ba19;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    int24 internal constant FULL_LOWER = -887_220;
    int24 internal constant FULL_UPPER = 887_220;
    uint256 internal constant SCAN_BLOCK = 58_599_621;
    uint256 internal constant POT = 1_000_000e18;

    IPoolManager internal pm;
    IPositionManager internal posm;
    LPRewards internal rewards;
    Emissions internal emissions;
    LPStreamer internal streamer;
    PoolKey internal key;
    PoolId internal poolId;
    address internal treasury = makeAddr("treasury");
    address internal attacker = makeAddr("attacker");
    uint256 internal capital = 100_000e18;
    uint256[] internal ids;

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 blk = vm.envOr("GAGE_FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);

        pm = IPoolManager(POOL_MANAGER);
        posm = IPositionManager(POSM);
        rewards = LPRewards(LP_REWARDS);
        emissions = Emissions(address(rewards.EMISSIONS()));
        key = rewards.poolKey();
        poolId = key.toId();
        streamer = new LPStreamer(IERC20(SGAGE), rewards);

        deal(SGAGE, treasury, POT);
        vm.prank(treasury);
        IERC20(SGAGE).approve(address(streamer), type(uint256).max);
        deal(GAGE, attacker, capital);
        deal(SGAGE, attacker, _gageToSgage(capital));
        vm.startPrank(attacker);
        IERC20(GAGE).approve(PERMIT2, type(uint256).max);
        IERC20(SGAGE).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(GAGE, POSM, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(PERMIT2).approve(SGAGE, POSM, type(uint160).max, type(uint48).max);
        vm.stopPrank();
        _discoverPositions();

        console2.log("fork block", block.number);
        console2.log("epoch", emissions.currentEpoch());
        console2.log("scoring positions", ids.length);
        console2.log("totalWeight (GAGE wei)", rewards.totalWeight());
    }

    function test_fork_streamer_paysHoldersAndNothingToAOneBlockPosition() public {
        uint256 e = emissions.currentEpoch();
        vm.prank(treasury);
        streamer.deposit(POT); // pot for epoch e + 1
        vm.warp(emissions.epochStart(e + 1));
        streamer.checkpointMany(ids); // first sight at the epoch start, as the keeper would
        uint256[] memory accrual0 = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            (accrual0[i],) = rewards.earned(ids[i]);
        }

        // the keeper's pre-boundary checkpoint, with the report's position minted in the same block
        vm.warp(emissions.epochStart(e + 2) - 10 minutes);
        uint256 jit = _mint(FULL_LOWER, FULL_UPPER);
        streamer.checkpoint(jit);
        streamer.checkpoint(jit);
        streamer.checkpointMany(ids);

        uint256 total;
        uint256 budget = rewards.emissionRate(e + 1) * emissions.EPOCH();
        for (uint256 i; i < ids.length; ++i) {
            (uint256 accrual,) = rewards.earned(ids[i]);
            uint256 got = streamer.earned(ids[i]);
            uint256 expected = Math.mulDiv(accrual - accrual0[i], POT, budget);
            assertApproxEqAbs(got, expected, 1, "paid exactly in proportion to the LPRewards accrual");
            total += got;
            console2.log("position / accrual / streamer credit", ids[i], accrual - accrual0[i], got);
        }
        console2.log("pot / paid to holders (sGAGE wei)", POT, total);
        console2.log("one-block position weight (GAGE wei)", rewards.positionState(jit).weight);
        console2.log("one-block position credit", streamer.earned(jit));

        assertEq(streamer.earned(jit), 0, "zero seconds of holding earns nothing");
        assertLe(total, POT, "never more than the pot");
        assertGt(total, (POT * 9) / 10, "the tracked holders take nearly all of it over the epoch");
        address owner = IERC721(POSM).ownerOf(ids[0]);
        vm.prank(owner);
        uint256 paid = streamer.collect(ids[0]);
        assertGt(paid, 0);
        assertEq(streamer.DRIP().getDrip(owner, streamer.dripIdOf(ids[0], 1)).total, paid, "into a 7-day drip");
    }

    // ----------------------------------------------------------------- positions

    function _discoverPositions() internal {
        uint256[14] memory known = [
            uint256(2_126_377),
            2_126_526,
            2_137_331,
            2_139_760,
            2_159_040,
            2_159_522,
            2_235_873,
            2_236_031,
            2_236_969,
            2_237_046,
            2_237_163,
            2_237_361,
            2_237_649,
            2_245_284
        ];
        uint256[] memory candidates = new uint256[](known.length + 256);
        uint256 n;
        for (; n < known.length; ++n) {
            candidates[n] = known[n];
        }
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("Checkpointed(uint256,uint256,uint256,bool)");
        if (block.number > SCAN_BLOCK) {
            try vm.eth_getLogs(SCAN_BLOCK + 1, block.number, LP_REWARDS, topics) returns (Vm.EthGetLogs[] memory logs) {
                for (uint256 i; i < logs.length && n < candidates.length; ++i) {
                    uint256 id = uint256(logs[i].topics[1]);
                    bool seen;
                    for (uint256 j; j < n; ++j) {
                        if (candidates[j] == id) seen = true;
                    }
                    if (!seen) candidates[n++] = id;
                }
            } catch {
                console2.log("eth_getLogs unavailable: using the scanned position list only");
            }
        }
        uint256 seed = rewards.seedTokenId();
        address floor = rewards.floor();
        for (uint256 i; i < n; ++i) {
            uint256 id = candidates[i];
            if (id == seed || posm.getPositionLiquidity(id) == 0) continue;
            (PoolKey memory k,) = posm.getPoolAndPositionInfo(id);
            if (PoolId.unwrap(k.toId()) != PoolId.unwrap(poolId)) continue;
            if (IERC721(POSM).ownerOf(id) == floor) continue;
            ids.push(id);
        }
        require(ids.length > 0, "no scoring positions");
    }

    function _mint(int24 lower, int24 upper) internal returns (uint256 tokenId) {
        (uint160 sqrtP,,,) = pm.getSlot0(poolId);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            capital / 2,
            _gageToSgage(capital / 2)
        );
        tokenId = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, lower, upper, uint256(liquidity), type(uint128).max, type(uint128).max, attacker, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.prank(attacker);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
    }

    /// @dev GAGE is currency0: price (sGAGE per GAGE) = sqrtP^2 / Q96^2.
    function _gageToSgage(uint256 g) internal view returns (uint256) {
        (uint160 sqrtP,,,) = pm.getSlot0(poolId);
        return Math.mulDiv(Math.mulDiv(g, sqrtP, FixedPoint96.Q96), sqrtP, FixedPoint96.Q96);
    }
}

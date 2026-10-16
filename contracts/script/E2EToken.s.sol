// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {DeploymentFile} from "./DeploymentFile.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {DealVault} from "../src/DealVault.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {DealRewards} from "../src/token/DealRewards.sol";
import {LPRewards} from "../src/token/LPRewards.sol";
import {Buyback} from "../src/token/Buyback.sol";
import {CreatorFeeSplitter} from "../src/token/CreatorFeeSplitter.sol";
import {ReinvestRouter} from "../src/token/ReinvestRouter.sol";
import {Drip} from "../src/token/Drip.sol";
import {IReinvestRouter} from "../src/interfaces/token/IReinvestRouter.sol";
import {Kind, Collateral} from "../src/types/Types.sol";
import {DealState, Deal} from "../src/interfaces/IDealVault.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Live end-to-end of M2 and the token layer after DeployTokenLayer.s.sol: register rewards for the M1
///         deals, list a real Uniswap v4 position as collateral and settle it, reinvest sGAGE into a hooked
///         GAGE/sGAGE position, collect and sweep fees into a buyback that burns, split a creator fee into an LP
///         lump, and collect LP rewards into a drip. Every step is checked before broadcast.
/// @dev Env: GAGE_DEPLOYMENT, TESTNET_DEPLOYER_KEY, BORROWER_KEY, LENDER_KEY, E2E_SKIP_COLLECT (optional).
contract E2EToken is DeploymentFile {
    using PoolIdLibrary for PoolKey;

    string internal path;
    DealVault internal vault;
    FeeSink internal feeSink;
    DealRewards internal dealRewards;
    LPRewards internal lpRewards;
    Buyback internal buyback;
    CreatorFeeSplitter internal splitter;
    ReinvestRouter internal reinvest;
    Drip internal drip;
    IPositionManager internal posm;
    IPoolManager internal poolManager;
    MockERC20 internal usdg;
    MockERC20 internal sgage;
    MockERC20 internal gage;
    PoolKey internal gageSgage;

    uint256 internal deployerKey;
    uint256 internal borrowerKey;
    uint256 internal lenderKey;
    address internal deployer;
    address internal borrower;
    address internal lender;
    uint256 internal borrowerPositionId;

    uint256 public positionDealId;
    uint256 public reinvestTokenId;
    uint256 public burned;

    function run() external {
        _load();
        _stepRegisterRewards();
        _stepPositionCollateral();
        _stepReinvest();
        _stepBuyback();
        _stepCreatorFee();
        // the collect needs fees to have accrued on the reinvest position; E2E_SKIP_COLLECT=true skips it right after a redeploy
        if (!vm.envOr("E2E_SKIP_COLLECT", false)) _stepCollectLP();
        _write();
    }

    // ----------------------------------------------------------------- steps

    function _stepRegisterRewards() internal {
        uint256[3] memory ids = [uint256(1), 2, 4];
        vm.startBroadcast(deployerKey);
        for (uint256 i = 0; i < ids.length; ++i) {
            if (!dealRewards.registered(ids[i])) dealRewards.register(ids[i]);
        }
        vm.stopBroadcast();
        for (uint256 i = 0; i < ids.length; ++i) {
            require(dealRewards.registered(ids[i]), "not registered");
            (uint128 total,,) = dealRewards.rewardOf(ids[i]);
            require(total > 0, "zero reward");
            Deal memory d = vault.getDeal(ids[i]);
            require(drip.getDrip(d.lender, dealRewards.dripIdOf(ids[i], d.lender)).total > 0, "lender drip");
            require(drip.getDrip(d.borrower, dealRewards.dripIdOf(ids[i], d.borrower)).total > 0, "borrower drip");
        }
    }

    /// @dev M2 live: the borrower lists its NVDAx/USDG position, the lender bids, the borrower accepts and reclaims.
    function _stepPositionCollateral() internal {
        vm.startBroadcast(borrowerKey);
        IERC721(address(posm)).setApprovalForAll(address(vault), true);
        positionDealId = vault.list(
            Collateral({kind: Kind.UNIV4_POSITION, token: address(posm), amountOrTokenId: borrowerPositionId}),
            500e6,
            1 days,
            uint40(block.timestamp + 3 days),
            0
        );
        vm.stopBroadcast();
        require(IERC721(address(posm)).ownerOf(borrowerPositionId) == address(vault), "vault holds the NFT");

        vm.startBroadcast(lenderKey);
        uint256 bidId = vault.bid(positionDealId, 400e6, uint40(block.timestamp + 2 days), lender);
        vm.stopBroadcast();

        vm.startBroadcast(borrowerKey);
        vault.accept(positionDealId, bidId);
        vault.reclaim(positionDealId);
        vault.withdrawPosition(borrowerPositionId);
        vm.stopBroadcast();
        require(vault.getDeal(positionDealId).state == DealState.RECLAIMED, "position deal not reclaimed");
        require(IERC721(address(posm)).ownerOf(borrowerPositionId) == borrower, "NFT back with the borrower");

        vm.startBroadcast(deployerKey);
        dealRewards.register(positionDealId);
        vm.stopBroadcast();
        (uint128 total,,) = dealRewards.rewardOf(positionDealId);
        require(total > 0, "position deal reward");
    }

    /// @dev The borrower pairs 5,000 sGAGE with GAGE bought with ETH; the hook records the new position.
    function _stepReinvest() internal {
        (, int24 tick) = _slot0();
        int24 mid = (tick / 60) * 60;
        IReinvestRouter.Range memory range = IReinvestRouter.Range({tickLower: mid - 3000, tickUpper: mid + 3000});
        vm.startBroadcast(borrowerKey);
        sgage.approve(address(reinvest), type(uint256).max);
        (reinvestTokenId,) = reinvest.reinvestMatch{value: 0.006 ether}(
            5000e18, range, IReinvestRouter.PayAsset.ETH, 0.006 ether, 1, block.timestamp + 1 hours
        );
        vm.stopBroadcast();
        require(IERC721(address(posm)).ownerOf(reinvestTokenId) == borrower, "reinvest position is the borrower's");
        require(lpRewards.positionState(reinvestTokenId).weight > 0, "hook recorded the position");
        require(sgage.balanceOf(address(reinvest)) == 0 && address(reinvest).balance == 0, "router not empty");
    }

    /// @dev Fees credited by the deals go FeeSink → Buyback → burn.
    function _stepBuyback() internal {
        uint256 supply = sgage.totalSupply();
        vm.startBroadcast(deployerKey);
        if (vault.balanceUSDG(address(feeSink)) > 0) feeSink.collect();
        if (usdg.balanceOf(address(feeSink)) > 0) feeSink.sweep();
        uint256 clip = usdg.balanceOf(address(buyback));
        if (clip > 2e6) clip = 2e6;
        burned = buyback.buyback(clip);
        vm.stopBroadcast();
        require(burned > 0 && sgage.totalSupply() == supply - burned, "buyback did not burn");
    }

    /// @dev A creator fee arrives (the deployer plays Pons), half goes to ops, half to LPs as sGAGE.
    function _stepCreatorFee() internal {
        vm.startBroadcast(deployerKey);
        (bool ok,) = address(splitter).call{value: 0.002 ether}("");
        require(ok, "fee transfer");
        uint256 gageToFloor = splitter.split();
        vm.stopBroadcast();
        require(gageToFloor > 0, "no GAGE to the floor");
        require(splitter.floorCount() == 1, "no floor band");
        (uint256 gageBacking,) = splitter.floorBacking();
        require(gageBacking > 0, "floor holds no GAGE");
    }

    function _stepCollectLP() internal {
        vm.startBroadcast(borrowerKey);
        (uint256 em, uint256 fee) = lpRewards.collect(reinvestTokenId);
        vm.stopBroadcast();
        require(fee > 0, "creator fee not paid");
        require(drip.getDrip(borrower, lpRewards.dripIdOf(reinvestTokenId, 1)).total == em, "emissions drip");
    }

    // ----------------------------------------------------------------- helpers

    function _load() internal {
        path = vm.envString("GAGE_DEPLOYMENT");
        string memory json = vm.readFile(path);
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "deployment is for another chain");
        vault = DealVault(vm.parseJsonAddress(json, ".DealVault"));
        feeSink = FeeSink(vm.parseJsonAddress(json, ".FeeSink"));
        dealRewards = DealRewards(vm.parseJsonAddress(json, ".DealRewards"));
        lpRewards = LPRewards(vm.parseJsonAddress(json, ".LPRewards"));
        buyback = Buyback(payable(vm.parseJsonAddress(json, ".Buyback")));
        splitter = CreatorFeeSplitter(payable(vm.parseJsonAddress(json, ".CreatorFeeSplitter")));
        reinvest = ReinvestRouter(payable(vm.parseJsonAddress(json, ".ReinvestRouter")));
        drip = Drip(vm.parseJsonAddress(json, ".Drip"));
        posm = IPositionManager(vm.parseJsonAddress(json, ".PositionManager"));
        poolManager = IPoolManager(vm.parseJsonAddress(json, ".PoolManager"));
        usdg = MockERC20(vm.parseJsonAddress(json, ".USDG"));
        sgage = MockERC20(vm.parseJsonAddress(json, ".sGAGE"));
        gage = MockERC20(vm.parseJsonAddress(json, ".GAGE"));
        gageSgage = lpRewards.poolKey();
        borrowerPositionId = vm.parseJsonUint(json, ".borrowerPositionId");
        deployerKey = vm.envUint("TESTNET_DEPLOYER_KEY");
        borrowerKey = vm.envUint("BORROWER_KEY");
        lenderKey = vm.envUint("LENDER_KEY");
        deployer = vm.addr(deployerKey);
        borrower = vm.addr(borrowerKey);
        lender = vm.addr(lenderKey);
    }

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(gageSgage.toId()), uint256(6)));
        bytes32 data = poolManager.extsload(slot);
        sqrtPriceX96 = uint160(uint256(data));
        tick = int24(int256(uint256(data) >> 160));
    }

    function _write() internal {
        _carryForward(vm.readFile(path));
        vm.serializeUint(OBJ, "positionDealId", positionDealId);
        string memory out = vm.serializeUint(OBJ, "reinvestTokenId", reinvestTokenId);
        vm.writeJson(out, path);
        console2.log("position deal (M2, reclaimed)", positionDealId);
        console2.log("reinvest position tokenId    ", reinvestTokenId);
        console2.log("sGAGE burned by the buyback  ", burned);
        console2.log("sGAGE total supply           ", sgage.totalSupply());
        console2.log("locked in Drip               ", drip.totalLocked());
    }
}

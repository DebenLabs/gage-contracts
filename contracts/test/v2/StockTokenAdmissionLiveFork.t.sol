// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {CommodityAdmissionLiveForkBase} from "./CommodityAdmissionLiveFork.t.sol";

// The Stock Token admission of 25 September 2026 (scripts/lib/stock-token-admission.mjs): CRCL, MSTR, GME and AMC as
// token-only STOCK collateral on the current V3 engine, each priced and cashed out through its canonical Uniswap v3
// token / USDG pool(s). The commodity base is the generic Stock Token suite (runtime equal to SPY, token / USDG v3 routes
// from the canonical factory), so it runs unchanged with the same GAGE_COMMODITY_FORK_RPC / _BLOCK environment.

/// CRCL, Circle Internet Group: one 0.3% v3 CRCL / USDG pool.
contract CrclAdmissionLiveForkTest is CommodityAdmissionLiveForkBase {
    function _token() internal pure override returns (address) {
        return 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0x654E4143e82a5824445Ade0824351C2A9ACD95a8;
    }

    function _min() internal pure override returns (uint256) {
        return 1.15e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 440e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 2200e18;
    }
}

/// MSTR, Strategy: one 1% v3 MSTR / USDG pool.
contract MstrAdmissionLiveForkTest is CommodityAdmissionLiveForkBase {
    function _token() internal pure override returns (address) {
        return 0xec262a75e413fAfD0dF80480274532C79D42da09;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0x17578C0e0D15da44f31677263114F71aE76653EA;
    }

    function _min() internal pure override returns (uint256) {
        return 0.65e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 80e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 400e18;
    }
}

/// GME, GameStop: the 1% v3 GME / USDG pool is the depth pool, the 0.05% pool a second cash-out route.
contract GmeAdmissionLiveForkTest is CommodityAdmissionLiveForkBase {
    function _token() internal pure override returns (address) {
        return 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](2);
        pools[0] = 0xE9713f453aDB9245B19559790c96F470a18F2fDF;
        pools[1] = 0xE2b46c905E12Ab8E2f864e4821a4325884C1B126;
    }

    function _min() internal pure override returns (uint256) {
        return 4.2e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 600e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 3000e18;
    }
}

/// AMC, AMC Entertainment: one 0.3% v3 AMC / USDG pool.
contract AmcAdmissionLiveForkTest is CommodityAdmissionLiveForkBase {
    function _token() internal pure override returns (address) {
        return 0x05a3d1Cd21d0C88145E82600E62e7E496e0F222B;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0xaA34feA710a1A737840329051D81D3B0B7C564d5;
    }

    function _min() internal pure override returns (uint256) {
        return 36e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 3200e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 16_000e18;
    }
}

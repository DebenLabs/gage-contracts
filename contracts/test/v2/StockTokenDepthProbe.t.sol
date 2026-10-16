// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// One-step exit sizing probe of the 25 September 2026 Stock Tokens (token -> USDG on the depth pool), the same probe as the
// commodity listing. Rerun at the weekly cap revisit. Skips without a fork RPC like the admission suite.
import {CommodityDepthProbe} from "./CommodityDepthProbe.t.sol";
import {
    CrclAdmissionLiveForkTest,
    MstrAdmissionLiveForkTest,
    GmeAdmissionLiveForkTest,
    AmcAdmissionLiveForkTest
} from "./StockTokenAdmissionLiveFork.t.sol";

contract CrclDepthProbeTest is CommodityDepthProbe, CrclAdmissionLiveForkTest {}

contract MstrDepthProbeTest is CommodityDepthProbe, MstrAdmissionLiveForkTest {}

contract GmeDepthProbeTest is CommodityDepthProbe, GmeAdmissionLiveForkTest {}

contract AmcDepthProbeTest is CommodityDepthProbe, AmcAdmissionLiveForkTest {}

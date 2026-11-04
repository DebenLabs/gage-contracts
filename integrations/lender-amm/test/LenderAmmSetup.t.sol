// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LenderAmmSetup} from "../script/LenderAmmSetup.sol";

/// @notice Neither of a pool's vaults lends against the pool's own currencies (docs/lender-amm.md, rule 8), so a fall
/// in one of them does not reach the LPs twice: by default each vault's collateral leaves both out, and a
/// `USDG_COLLATERAL` list naming one stops the script. Read from a manifest's text, so no fork is needed.
contract LenderAmmSetupTest is Test, LenderAmmSetup {
    address internal constant POOL_MANAGER = address(0x1000);
    address internal constant USDG = address(0x1001);
    address internal constant GLDX = address(0x1002);
    address internal constant NVDAX = address(0x1003);
    address internal constant TSLAX = address(0x1004);
    address internal constant MSFTX = address(0x1005);
    address internal constant HOODX = address(0x1006);
    address internal constant SCHIFFYX = address(0x1007);
    address internal constant NVDOG = address(0x1008);
    address internal constant CURATOR = address(0x5afe);

    /// @dev A manifest as gage publishes it, cut to what the kit reads: GLDx's generation lends against a meme, NVDAx's
    /// against a meme and USDG (the testnet's), HOODx's against USDG alone.
    function _json() internal pure returns (string memory) {
        string memory tokens = string.concat(
            _key("PoolManager", POOL_MANAGER),
            _key("USDG", USDG),
            _key("GLDx", GLDX),
            _key("NVDAx", NVDAX),
            _key("TSLAx", TSLAX),
            _key("MSFTx", MSFTX)
        );
        string memory generations = string.concat(
            _generation("GLDx", GLDX, address(0x2001), _tokens(SCHIFFYX)),
            ",",
            _generation("NVDAx", NVDAX, address(0x2002), string.concat(_tokens(NVDOG), ",", _tokens(USDG))),
            ",",
            _generation("HOODx", HOODX, address(0x2003), _tokens(USDG))
        );
        string memory pools =
            string.concat(_pool("gldxUsdg", 1), ",", _pool("nvdaxUsdg", 2), ",", _pool("hoodxUsdg", 3));
        return string.concat(
            "{",
            tokens,
            '"intentV1":{"factory":"',
            vm.toString(address(0x2000)),
            '"},"intentV1Assets":{',
            generations,
            '},"pools":{',
            pools,
            "}}"
        );
    }

    function _key(string memory key, address token) internal pure returns (string memory) {
        return string.concat('"', key, '":"', vm.toString(token), '",');
    }

    function _pool(string memory name, uint256 id) internal pure returns (string memory) {
        return string.concat('"', name, '":{"poolId":"', vm.toString(bytes32(id)), '"}');
    }

    function _generation(string memory symbol, address token, address factory, string memory collateral)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '"',
            symbol,
            '":{"lendAsset":{"token":"',
            vm.toString(token),
            '"},"factory":"',
            vm.toString(factory),
            '","collateral":[',
            collateral,
            "]}"
        );
    }

    function _tokens(address token) internal pure returns (string memory) {
        return string.concat('{"token":"', vm.toString(token), '"}');
    }

    /// @dev `_networkOf` as a call, so a refusal can be expected.
    function networkOf(string memory json, string memory symbol, string memory usdgKeys)
        external
        view
        returns (Network memory)
    {
        return _networkOf(json, symbol, usdgKeys);
    }

    /// @dev By default the USDG vault lends against the default real-world assets less the pool's lend asset, and the
    /// lend asset's vault against its generation's collateral less USDG; the mandates carry exactly those.
    function test_defaults_leaveBothPoolCurrenciesOut() public {
        Network memory n = _networkOf(_json(), "NVDAx", "");
        assertEq(n.usdgCollateral, _list(GLDX, TSLAX, MSFTX), "USDG's vault: the default list less NVDAx");
        assertEq(n.assetCollateral, _list(NVDOG), "NVDAx's vault: its generation's collateral less USDG");
        vm.mockCall(NVDAX, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(18)));
        assertEq(_usdgMandate(n, CURATOR).assets, _list(GLDX, TSLAX, MSFTX));
        assertEq(_assetMandate(n, CURATOR).assets, _list(NVDOG));

        n = _networkOf(_json(), "GLDx", "");
        assertEq(n.usdgCollateral, _list(NVDAX, TSLAX, MSFTX), "USDG's vault: the default list less GLDx");
        assertEq(n.assetCollateral, _list(SCHIFFYX));
    }

    /// @dev A `USDG_COLLATERAL` list is the partner's, taken as written, but never with a pool currency in it.
    function test_namedList_isTakenAsWritten_butNeverWithAPoolCurrency() public {
        assertEq(this.networkOf(_json(), "NVDAx", "TSLAx,GLDx").usdgCollateral, _list(TSLAX, GLDX));
        vm.expectRevert(
            bytes(
                "USDG_COLLATERAL names NVDAx, a currency of the NVDAx/USDG pool: a vault never lends against its pool's currencies (docs/lender-amm.md, rule 8)"
            )
        );
        this.networkOf(_json(), "NVDAx", "TSLAx,NVDAx");
        vm.expectRevert(
            bytes(
                "USDG_COLLATERAL names USDG, a currency of the GLDx/USDG pool: a vault never lends against its pool's currencies (docs/lender-amm.md, rule 8)"
            )
        );
        this.networkOf(_json(), "GLDx", "USDG");
    }

    /// @dev A generation that lends only against USDG leaves its vault nothing to lend against: the script stops.
    function test_aGenerationLendingOnlyAgainstThePool_isRefused() public {
        vm.expectRevert(bytes("the HOODx generation admits no collateral but the pool's currencies"));
        this.networkOf(_json(), "HOODx", "");
    }

    /// @dev The same on the testnet's manifest as committed (the fork suite's), whatever its generations lend against.
    function test_testnetManifest_defaultsLeaveBothPoolCurrenciesOut() public {
        vm.chainId(46_630);
        string memory json = _manifest();
        string[2] memory symbols = ["GLDx", "NVDAx"];
        for (uint256 i; i < symbols.length; ++i) {
            if (!vm.keyExistsJson(json, string.concat(".intentV1Assets.", symbols[i]))) continue;
            Network memory n = _networkOf(json, symbols[i], "");
            assertGt(n.usdgCollateral.length, 0);
            assertGt(n.assetCollateral.length, 0);
            _assertNoPoolCurrency(n, n.usdgCollateral);
            _assertNoPoolCurrency(n, n.assetCollateral);
        }
    }

    function _assertNoPoolCurrency(Network memory n, address[] memory collateral) internal pure {
        for (uint256 i; i < collateral.length; ++i) {
            assertTrue(collateral[i] != n.usdg && collateral[i] != n.asset, "a pool currency as collateral");
        }
    }

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        (l[0], l[1]) = (a, b);
    }

    function _list(address a, address b, address c) internal pure returns (address[] memory l) {
        l = new address[](3);
        (l[0], l[1], l[2]) = (a, b, c);
    }
}

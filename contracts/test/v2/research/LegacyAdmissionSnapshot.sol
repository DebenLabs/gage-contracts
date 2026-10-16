// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @dev Verified registry inventory at mainnet block 58066101. Research fixture only.
library LegacyAdmissionSnapshot {
    function tokens() internal pure returns (address[] memory out) {
        out = new address[](30);
        out[0] = address(bytes20(hex"0bd7d308f8e1639fab988df18a8011f41eacad73"));
        out[1] = address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"));
        out[2] = address(bytes20(hex"4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea"));
        out[3] = address(bytes20(hex"af3d76f1834a1d425780943c99ea8a608f8a93f9"));
        out[4] = address(bytes20(hex"d0601ce157db5bdc3162bbac2a2c8af5320d9eec"));
        out[5] = address(bytes20(hex"2e0847e8910a9732eb3fb1bb4b70a580adad4fe3"));
        out[6] = address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d"));
        out[7] = address(bytes20(hex"1d11f0496982706c5e14a514d4e79f2e6bde4516"));
        out[8] = address(bytes20(hex"c0d6457c16cc70d6790dd43521c899c87ce02f35"));
        out[9] = address(bytes20(hex"894e1ec2d74ffe5aef8dc8a9e84686accb964f2a"));
        out[10] = address(bytes20(hex"ff080c8ce2e5feadaca0da81314ae59d232d4afd"));
        out[11] = address(bytes20(hex"ccee82fe024c36fa15e1005ede3e9e4787e23d09"));
        out[12] = address(bytes20(hex"2e8c31162b855a2ffa90f6f8634643ad6f111e18"));
        out[13] = address(bytes20(hex"98096d17e191b3da1d5f99a6d7b3584351b11e18"));
        out[14] = address(bytes20(hex"d9db30bb0d2b8d2eae3826a1372117e058791e18"));
        out[15] = address(bytes20(hex"fe7e19cbce2f896c6c528bc355baf5a768291e18"));
        out[16] = address(bytes20(hex"5d6ef090a1461b11c9427ac319260122d1c61e18"));
        out[17] = address(bytes20(hex"6b1d42927b1a84ec28fa88d4fc6fa7af404966be"));
        out[18] = address(bytes20(hex"a9efe2fc94de79734c03051515f48f254ce61e18"));
        out[19] = address(bytes20(hex"a3b6aee90017b72c0812dc1e013de70eb2917ba3"));
        out[20] = address(bytes20(hex"451b42a15100c340ca12f7c66de06fac5ea2d751"));
        out[21] = address(bytes20(hex"0ff9072a1ead154d92c2d2fef16afba6028ce2b2"));
        out[22] = address(bytes20(hex"39dbed3a2bd333467115de45665cc57f813c4571"));
        out[23] = address(bytes20(hex"ab093def657f15df31b33922a95e047add645b29"));
        out[24] = address(bytes20(hex"f6589f11bc40b669e584073f428b05562f568733"));
        out[25] = address(bytes20(hex"be98b75361935b18d688409424a869a4c3dc7401"));
        out[26] = address(bytes20(hex"45242320dbb855eea8fd36804c6487e10e97fcf9"));
        out[27] = address(bytes20(hex"020bfc650a365f8bb26819deaabf3e21291018b4"));
        out[28] = address(bytes20(hex"385f4f8ae47651ce5f58f5265395a669f8281e18"));
        out[29] = address(bytes20(hex"18e674231a58c239dc7daedcffe15ec3a24cff5c"));
    }

    function pools() internal pure returns (bytes32[] memory out) {
        out = new bytes32[](9);
        out[0] = 0xcbdfea90430a30ee4469c9902e120a77e7c7e4711d5643671c1d1957f2f1ce27;
        out[1] = 0x9c89b04303dfa76f3f6fb02c2b77be0e8a00ab8fa00d507119acd54ab3e8640d;
        out[2] = 0xc3cc877a8a7d28efdb5dbec9ae71724652431e6411aa1a9fc8928028da554aa1;
        out[3] = 0x225cc98f7d66b29fef96377becc7bf89582e2ab7b923a09aee9719fd80eb94ca;
        out[4] = 0xc39187cec78a076c41a4085598b4cc05be2ed9b04a3443167471fa0fc4984188;
        out[5] = 0xf224a070c8626c890a085b258cf562ee4bf052b6d1d59104b3b44d722640c001;
        out[6] = 0x141be60316aeb3aa7c0e0d8e4fbdc0aa78105e6e462cfc03b8a0f0c59f0bf3f8;
        out[7] = 0x1fb9a45079b017a6661016ba7dea29e1c4864b0874c21f63e137a52e71c3395b;
        out[8] = 0xbacecf788d2279f65da62d7bf69f4de28580a88bec56847c8d2ba6fbdd73f6eb;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ReactiveTest } from "./Reactive.t.sol";
import { VaultTest } from "./Vault.t.sol";
import { E2ETest } from "./E2E.t.sol";

/// @notice The same suites, re-run with Ethereum Sepolia as origin/destination
///         and the official Ethereum Sepolia callback proxy.  This proves the
///         subscription chain id, the vault's proxy binding and the callback
///         authentication path are not Base-specific.
contract SepoliaReactiveTest is ReactiveTest {
    function originChainId() internal pure override returns (uint256) {
        return 11155111;
    }

    function callbackProxy() internal pure override returns (address) {
        return 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;
    }
}

contract SepoliaVaultTest is VaultTest {
    function originChainId() internal pure override returns (uint256) {
        return 11155111;
    }

    function callbackProxy() internal pure override returns (address) {
        return 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;
    }
}

contract SepoliaE2ETest is E2ETest {
    function originChainId() internal pure override returns (uint256) {
        return 11155111;
    }

    function callbackProxy() internal pure override returns (address) {
        return 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;
    }
}

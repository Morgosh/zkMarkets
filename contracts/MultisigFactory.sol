// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@matterlabs/zksync-contracts/l2/system-contracts/Constants.sol";
import "@matterlabs/zksync-contracts/l2/system-contracts/libraries/SystemContractsCaller.sol";

contract MultisigFactory {
    bytes32 public aaBytecodeHash;
    address[] public deployedAccounts; // Storage for deployed account addresses

    constructor(bytes32 _aaBytecodeHash) {
        aaBytecodeHash = _aaBytecodeHash;
    }

    function deployAccount(
        bytes32 salt,
        address owner1,
        address owner2,
        address emergencyWallet  // <-- Add this
    ) external returns (address accountAddress) {
        (bool success, bytes memory returnData) = SystemContractsCaller
            .systemCallWithReturndata(
                uint32(gasleft()),
                address(DEPLOYER_SYSTEM_CONTRACT),
                uint128(0),
                abi.encodeCall(
                    DEPLOYER_SYSTEM_CONTRACT.create2Account,
                    (salt, aaBytecodeHash, abi.encode(owner1, owner2, emergencyWallet), IContractDeployer.AccountAbstractionVersion.Version1) // <-- Modify this
                )
            );
        require(success, "Deployment failed");

        (accountAddress) = abi.decode(returnData, (address));

        deployedAccounts.push(accountAddress); // Store the deployed account address

        return accountAddress;
    }

    function getDeployedAccounts() external view returns (address[] memory) {
        return deployedAccounts;
    }
}

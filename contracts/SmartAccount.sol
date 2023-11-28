// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@matterlabs/zksync-contracts/l2/system-contracts/interfaces/IAccount.sol";
import "@matterlabs/zksync-contracts/l2/system-contracts/libraries/TransactionHelper.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
// Used for signature validation
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
// Access zkSync system contracts for nonce validation via NONCE_HOLDER_SYSTEM_CONTRACT
import "@matterlabs/zksync-contracts/l2/system-contracts/Constants.sol";
// to call non-view function of system contracts
import "@matterlabs/zksync-contracts/l2/system-contracts/libraries/SystemContractsCaller.sol";
import "./libraries/SpendLimit.sol";
import "./libraries/Guardians.sol";
//import "./libraries/Base.sol";

/**
 * @title SmartAccount
 * @author zkMarkets
 */


contract SmartAccount is IAccount, IERC1271, SpendLimit, Guardians { //, Base

    using TransactionHelper for Transaction;

    constructor(address _owner, address _registryAddress) Guardians(_owner, _registryAddress)  {
        // Set the owner of the contract
        owner = _owner;
    }

    bytes4 constant EIP1271_SUCCESS_RETURN_VALUE = 0x1626ba7e;

    modifier onlyBootloader() {
        require(
            msg.sender == BOOTLOADER_FORMAL_ADDRESS,
            "Only bootloader can call this function"
        );
        _;
    }

    function validateTransaction(
        bytes32,
        bytes32 _suggestedSignedHash,
        Transaction calldata _transaction
    ) external payable override onlyBootloader returns (bytes4 magic) {
        return _validateTransaction(_suggestedSignedHash, _transaction);
    }

    function _validateTransaction(
        bytes32 _suggestedSignedHash,
        Transaction calldata _transaction
    ) internal returns (bytes4 magic) {

        // Incrementing the nonce of the account.
        // Note, that reserved[0] by convention is currently equal to the nonce passed in the transaction
        SystemContractsCaller.systemCallWithPropagatedRevert(
            uint32(gasleft()),
            address(NONCE_HOLDER_SYSTEM_CONTRACT),
            0,
            abi.encodeCall(INonceHolder.incrementMinNonceIfEquals, (_transaction.nonce))
        );

        bytes32 txHash;
        // While the suggested signed hash is usually provided, it is generally
        // not recommended to rely on it to be present, since in the future
        // there may be tx types with no suggested signed hash.
        if (_suggestedSignedHash == bytes32(0)) {
            txHash = _transaction.encodeHash();
        } else {
            txHash = _suggestedSignedHash;
        }

        // The fact there is enough balance for the account
        // should be checked explicitly to prevent user paying for fee for a
        // transaction that wouldn't be included on Ethereum.
        uint256 totalRequiredBalance = _transaction.totalRequiredBalance();
        require(totalRequiredBalance <= address(this).balance, "Not enough balance for fee + value");

        if (isValidSignature(txHash, _transaction.signature) == EIP1271_SUCCESS_RETURN_VALUE) {
            magic = ACCOUNT_VALIDATION_SUCCESS_MAGIC;
        } else {
            magic = bytes4(0);
        }
    }

    struct Call {
        address payable target;
        bytes callData;
        uint256 value;
    }

    function executeTransaction(
        bytes32, 
        bytes32, 
        Transaction calldata _transaction
    ) external payable override onlyBootloader {
        _executeTransaction(_transaction);
    }

    function multicall(Call[] memory calls) public payable {
        // If the caller is not this contract, return without executing any calls
        if (msg.sender != address(this)) {
            return;
        }

        uint256 length = calls.length;
        for (uint256 i = 0; i < length; i++) {
            bool success;
            Call memory call = calls[i];
            (success, ) = call.target.call{value: call.value}(call.callData);
            require(success, "Multicall: call failed");
        }
    }

    function _executeTransaction(Transaction calldata _transaction) internal isUnlocked {
        address to = address(uint160(_transaction.to));

        // Call SpendLimit contract to ensure that ETH `value` doesn't exceed the daily spending limit
        uint128 value = Utils.safeCastToU128(_transaction.value);
        if (value > 0) {
            _checkSpendingLimit(address(ETH_TOKEN_SYSTEM_CONTRACT), value);
        }
        // Step 2.1: Check if the "to" address is the contract itself
        if (address(uint160(_transaction.to)) == address(this)) {

            // Step 2.2: Check if the data is a call to the "multicall" function
            bytes calldata calldataData = _transaction.data;
            bytes4 functionSelector = bytes4(keccak256("multicall(Call[])"));
            bytes4 dataFunctionSelector;
            if (calldataData.length >= 4) {
                assembly {
                    dataFunctionSelector := calldataload(0x20)
                }
            }

            if (dataFunctionSelector == functionSelector) {
                // Step 2.3: Decode the calls from the data
                Call[] memory calls = abi.decode(calldataData[4:], (Call[]));

                // Step 2.4: Call the "multicall" function
                multicall(calls);
                return;
            }
        }
        // If not a multicall, proceed as normal

        bytes memory data = _transaction.data;
        if (to == address(DEPLOYER_SYSTEM_CONTRACT)) {
            uint32 gas = Utils.safeCastToU32(gasleft());

            // Note, that the deployer contract can only be called
            // with a "systemCall" flag.
            SystemContractsCaller.systemCallWithPropagatedRevert(gas, to, value, data);
        } else {
            bool success;
            assembly {
                success := call(gas(), to, value, add(data, 0x20), mload(data), 0, 0)
            }
            require(success);
        }
    }

    function executeTransactionFromOutside(Transaction calldata _transaction)
        external
        payable
    {
        _validateTransaction(bytes32(0), _transaction);
        _executeTransaction(_transaction);
    }

    // Accounts for prefix on the signature since we're using signMessage method
    function prefixed(bytes32 _hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", _hash));
    }

    function isValidSignature(bytes32 _hash, bytes memory _signature) public view override returns (bytes4 magic) {
        magic = EIP1271_SUCCESS_RETURN_VALUE;

        if (_signature.length != 65) { // for a single ECDSA signature, it should be 65 bytes
            // Signature is invalid anyway, but we need to proceed with the signature verification
            _signature = new bytes(65);
            
            // Making sure that the signatures look like a valid ECDSA signature and are not rejected right away
            _signature[64] = bytes1(uint8(27));
        }

        if (!checkValidECDSASignatureFormat(_signature)) {
            magic = bytes4(0);
            return magic;
        }

        bytes32 prefixedHash = prefixed(_hash);
        (address recoveredAddr1, ECDSA.RecoverError error1) = ECDSA.tryRecover(prefixedHash, _signature);
        if (error1 != ECDSA.RecoverError.NoError)  {
            magic = bytes4(0);
            return magic;
        }

        if (recoveredAddr1 != owner) {
            (address recoveredAddr2, ECDSA.RecoverError error2) = ECDSA.tryRecover(_hash, _signature);
            if (error2 != ECDSA.RecoverError.NoError || recoveredAddr2 != owner) {
                magic = bytes4(0);
            }
        }

        return magic;
    }

    // This function verifies that the ECDSA signature is both in correct format and non-malleable
    function checkValidECDSASignatureFormat(bytes memory _signature) internal pure returns (bool) {
        if(_signature.length != 65) {
            return false;
        }

        uint8 v;
		bytes32 r;
		bytes32 s;
		// Signature loading code
		// we jump 32 (0x20) as the first slot of bytes contains the length
		// we jump 65 (0x41) per signature
		// for v we load 32 bytes ending with v (the first 31 come from s) then apply a mask
		assembly {
			r := mload(add(_signature, 0x20))
			s := mload(add(_signature, 0x40))
			v := and(mload(add(_signature, 0x41)), 0xff)
		}
		if(v != 27 && v != 28) {
            return false;
        }

		// EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if(uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return false;
        }

        return true;
    }

    function extractECDSASignature(bytes memory _fullSignature) internal pure returns (bytes memory signature1, bytes memory signature2) {
        require(_fullSignature.length == 130, "Invalid length");

        signature1 = new bytes(65);
        signature2 = new bytes(65);

        // Copying the first signature. Note, that we need an offset of 0x20
        // since it is where the length of the `_fullSignature` is stored
        assembly {
            let r := mload(add(_fullSignature, 0x20))
			let s := mload(add(_fullSignature, 0x40))
			let v := and(mload(add(_fullSignature, 0x41)), 0xff)

            mstore(add(signature1, 0x20), r)
            mstore(add(signature1, 0x40), s)
            mstore8(add(signature1, 0x60), v)
        }

        // Copying the second signature.
        assembly {
            let r := mload(add(_fullSignature, 0x61))
            let s := mload(add(_fullSignature, 0x81))
            let v := and(mload(add(_fullSignature, 0x82)), 0xff)

            mstore(add(signature2, 0x20), r)
            mstore(add(signature2, 0x40), s)
            mstore8(add(signature2, 0x60), v)
        }
    }

    function payForTransaction(
        bytes32,
        bytes32,
        Transaction calldata _transaction
    ) external payable override onlyBootloader {
        bool success = _transaction.payToTheBootloader();
        require(success, "Failed to pay the fee to the operator");
    }

    function prepareForPaymaster(
        bytes32, // _txHash
        bytes32, // _suggestedSignedHash
        Transaction calldata _transaction
    ) external payable override onlyBootloader {
        _transaction.processPaymasterInput();
    }

    fallback() external {
        // fallback of default account shouldn't be called by bootloader under no circumstances
        assert(msg.sender != BOOTLOADER_FORMAL_ADDRESS);

        // If the contract is called directly, behave like an EOA
    }

    receive() external payable {
        // If the contract is called directly, behave like an EOA.
        // Note, that is okay if the bootloader sends funds with no calldata as it may be used for refunds/operator payments
    }

    function onERC721Received(
        address operator, 
        address from, 
        uint256 tokenId, 
        bytes calldata data
    ) 
        external 
        returns(bytes4) 
    {
        // Here you can add logic that you want to execute when your contract receives an ERC-721 token.
        return this.onERC721Received.selector;  // Must return this specific magic value.
    }
}

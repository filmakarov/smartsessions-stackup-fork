// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import "../DataTypes.sol";
import { EfficientHashLib } from "solady/utils/EfficientHashLib.sol";

import "forge-std/console2.sol";

// Typehashes
string constant POLICY_DATA_NOTATION = "PolicyData(address policy,bytes initData)";
string constant ACTION_DATA_NOTATION = "ActionData(bytes32 actionId,PolicyData[] actionPolicies)";
string constant ERC7739_DATA_NOTATION = "ERC7739Data(string[] allowedERC7739Content,PolicyData[] erc1271Policies)";

bytes32 constant POLICY_DATA_TYPEHASH = keccak256(bytes(POLICY_DATA_NOTATION));
bytes32 constant ACTION_DATA_TYPEHASH = keccak256(bytes(ACTION_DATA_NOTATION));
bytes32 constant ERC7739_DATA_TYPEHASH = keccak256(bytes(ERC7739_DATA_NOTATION));

string constant SESSION_NOTATION = "Session(uint8 mode,address isigner,bytes32 salt,bytes isignerInitData,PolicyData[] userOpPolicies,ERC7739Data erc7739Policies,ActionData[] actions)";
string constant CHAIN_SESSION_NOTATION = "ChainSession(uint64 chainId,Session session)";
string constant MULTI_CHAIN_SESSION_NOTATION = "MultiChainSession(ChainSession[] sessionsAndChainIds)";

bytes32 constant SESSION_TYPEHASH = keccak256(
    abi.encodePacked(bytes(SESSION_NOTATION), bytes(POLICY_DATA_NOTATION), bytes(ACTION_DATA_NOTATION), bytes(ERC7739_DATA_NOTATION))
);

bytes32 constant CHAIN_SESSION_TYPEHASH = keccak256(
    abi.encodePacked(bytes(CHAIN_SESSION_NOTATION), bytes(SESSION_NOTATION), bytes(POLICY_DATA_NOTATION), bytes(ACTION_DATA_NOTATION), bytes(ERC7739_DATA_NOTATION))
);

bytes32 constant MULTICHAIN_SESSION_TYPEHASH = keccak256(
    abi.encodePacked(bytes(MULTI_CHAIN_SESSION_NOTATION), bytes(CHAIN_SESSION_NOTATION), bytes(SESSION_NOTATION), bytes(POLICY_DATA_NOTATION), bytes(ACTION_DATA_NOTATION), bytes(ERC7739_DATA_NOTATION))
);


library HashLib {

    error ChainIdMismatch(uint64 providedChainId);
    error HashMismatch(bytes32 providedHash, bytes32 computedHash);

    using EfficientHashLib for bytes32;
    using HashLib for *;

    // the object that is passed to signTypedData() is MultiChainSession
    // signTypedData signs it as per eip-712
    // 1. hashStruct(Session)
    // 2. hashStruct(ChainSession)
    // 3. abi.encodePacked 2's together
    // + domain separator (we can take fake one)
    // so we have to do same, just w/o 1. as it is already provided to us as a digest

    // SHOULD MIMIC SignTypedData() behaviour
    function multichainDigest(ChainDigest[] memory hashesAndChainIds) internal pure returns (bytes32) {  
        bytes32 _hash = keccak256(
            abi.encode(
                MULTICHAIN_SESSION_TYPEHASH,
                hashesAndChainIds.hashChainDigestArray()
            )
        );

        return _hash;
        // TODO: ADD EIP 712 domain separator
        // for multichain 
    }

    function hashChainDigestArray(ChainDigest[] memory chainDigestArray) internal pure returns (bytes32) {
        uint256 length = chainDigestArray.length;
        bytes32[] memory hashes = new bytes32[](length);
        for (uint256 i; i < length; i++) {
            hashes[i] = chainDigestArray[i].hashChainDigestMimicRPC();
        }
        return keccak256(abi.encodePacked(hashes));
    }

    // we have session digests, however to mimic signTypedData() behaviour, we need to use CHAIN_SESSION_TYPEHASH
    // not CHAIN_DIGEST_TYPEHASH. We just use sessionDigest instead of rebuilding it
    function hashChainDigestMimicRPC(ChainDigest memory chainDigest) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            CHAIN_SESSION_TYPEHASH, 
            chainDigest.chainId, 
            chainDigest.sessionDigest // this is the digest obtained using sessionDigest()
            // we just do not rebuild it here for all sessions, but receive it from off-chain
        ));
    }

    // need to provide modes and nonces from outside as they are from other chains
    function multichainDigest(
        MultiChainSession memory multichainSession, 
        SmartSessionMode[] memory modes,
        uint256[] memory nonces
    ) internal pure returns (bytes32) {  
        // make hash from the full sessions => should return same hash as signTypedData()
        // and should return same hash as multichainDigest(ChainDigest[])
        
        // multichainSession.sessionsAndChainIds
        bytes32 _hash = keccak256(
            abi.encode(
                MULTICHAIN_SESSION_TYPEHASH,
                multichainSession.sessionsAndChainIds.hashChainSessionArray(modes, nonces)
            )
        );
        return _hash;
    }

    function hashChainSessionArray(
        ChainSession[] memory chainSessionArray,
        SmartSessionMode[] memory modes,
        uint256[] memory nonces
    ) internal pure returns (bytes32) {
        uint256 length = chainSessionArray.length;
        bytes32[] memory hashes = new bytes32[](length);
        for (uint256 i; i < length; i++) {
            hashes[i] = chainSessionArray[i].hashChainSession(modes[i], nonces[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function hashChainSession(
        ChainSession memory chainSession,
        SmartSessionMode mode,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            CHAIN_SESSION_TYPEHASH, 
            chainSession.chainId, 
            chainSession.session.sessionDigest(mode, nonce)
        ));
    }

    // it is exactly how signTypedData will hash Such an object
    // when this object is an inner struct
    // it won't use eip712 domain for it as it is inner struct
    function sessionDigest(
        Session memory session,
        SmartSessionMode mode,
        uint256 nonce
    )
        internal
        pure
        returns (bytes32 _hash)
    {   
        // add account address, smart session address here
        _hash = keccak256(
            abi.encode(
                SESSION_TYPEHASH,
                uint8(mode), // Include mode as uint8
                address(session.isigner),
                session.salt,
                keccak256(session.isignerInitData),
                session.userOpPolicies.hashPolicyDataArray(),
                session.erc7739Policies.hashERC7739Data(),
                session.actions.hashActionDataArray(),
                nonce
            )
        );
    }

    function hashPolicyData(PolicyData memory policyData) internal pure returns (bytes32) {
        return keccak256(abi.encode(POLICY_DATA_TYPEHASH, policyData.policy, keccak256(policyData.initData)));
    }

    function hashPolicyDataArray(PolicyData[] memory policyDataArray) internal pure returns (bytes32) {
        uint256 length = policyDataArray.length;
        bytes32[] memory hashes = new bytes32[](length);
        for (uint256 i; i < length; i++) {
            hashes[i] = policyDataArray[i].hashPolicyData();
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function hashActionData(ActionData memory actionData) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(ACTION_DATA_TYPEHASH, actionData.actionId, hashPolicyDataArray(actionData.actionPolicies))
        );
    }

    function hashActionDataArray(ActionData[] memory actionDataArray) internal pure returns (bytes32) {
        uint256 length = actionDataArray.length;
        bytes32[] memory hashes = new bytes32[](length);
        for (uint256 i; i < length; i++) {
            hashes[i] = actionDataArray[i].hashActionData();
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function hashERC7739Data(ERC7739Data memory erc7739Data) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ERC7739_DATA_TYPEHASH,
                erc7739Data.allowedERC7739Content.hashStringArray(),
                erc7739Data.erc1271Policies.hashPolicyDataArray()
            )
        );
    }

    function hashStringArray(string[] memory stringArray) internal pure returns (bytes32) {
        uint256 length = stringArray.length;
        bytes32[] memory hashes = new bytes32[](length);
        for (uint256 i; i < length; i++) {
            hashes[i] = keccak256(abi.encodePacked(stringArray[i]));
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function hashERC7739Content(string memory content) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(content));
    }

    function getAndVerifyDigest(EnableSessions memory enableData, uint256 nonce, SmartSessionMode mode) internal view returns (bytes32 digest) {
        bytes32 computedHash = enableData.sessionToEnable.sessionDigest(mode, nonce);
        
        uint64 providedChainId = enableData.hashesAndChainIds[enableData.sessionIndex].chainId;
        bytes32 providedHash =  enableData.hashesAndChainIds[enableData.sessionIndex].sessionDigest;

        if (providedChainId != block.chainid) {
            revert ChainIdMismatch(providedChainId);
        }

        // ensure digest we've built from the sessionToEnable is included into
        // the list of digests that were signed
        if (providedHash != computedHash) {
            revert HashMismatch(providedHash, computedHash);
        }

        digest = enableData.hashesAndChainIds.multichainDigest();
    }
}

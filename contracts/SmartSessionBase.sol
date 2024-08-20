// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import "./DataTypes.sol";
import "./utils/EnumerableSet4337.sol";

import { ISigner } from "./interfaces/ISigner.sol";
import "@rhinestone/flatbytes/src/BytesLib.sol";
import { SentinelList4337Lib } from "sentinellist/SentinelList4337.sol";
import { ERC7579ValidatorBase } from "modulekit/Modules.sol";
import { ConfigLib } from "./lib/ConfigLib.sol";
import { EncodeLib } from "./lib/EncodeLib.sol";
import { IdLib } from "./lib/IdLib.sol";

abstract contract SmartSessionBase is ERC7579ValidatorBase {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using FlatBytesLib for *;
    using ConfigLib for *;
    using EncodeLib for *;
    using IdLib for *;
    using SentinelList4337Lib for SentinelList4337Lib.SentinelList;
    using AssociatedArrayLib for *;
    using ConfigLib for Policy;
    using ConfigLib for EnumerableActionPolicy;

    error InvalidISigner(ISigner isigner);
    error InvalidSession(SignerId signerId);

    event SessionCreated(SignerId signerId, address account);
    event SessionRemoved(SignerId signerId, address smartAccount);

    error InvalidData();

    Policy internal $userOpPolicies;
    Policy internal $erc1271Policies;
    EnumerableActionPolicy internal $actionPolicies;
    EnumerableSet.Bytes32Set internal $enabledSessions;
    mapping(ISigner signer => mapping(address smartAccount => uint256 nonce)) internal $signerNonce;
    mapping(SignerId signerId => mapping(address smartAccount => SignerConf)) internal $isigners;

    function _enableISigner(SignerId signerId, address account, ISigner isigner, bytes memory signerConfig) internal {
        if (!isigner.supportsInterface(type(ISigner).interfaceId)){
            revert InvalidISigner(isigner);
        }
        // TODO: add registry check
        SignerConf storage $conf = $isigners[signerId][account];
        $conf.isigner = isigner;
        $conf.config.store(signerConfig);
        $enabledSessions.add(account, SignerId.unwrap(signerId));
    }

    function enableUserOpPolicies(SignerId signerId, PolicyData[] memory userOpPolicies) public {
        if ($enabledSessions.contains(msg.sender, SignerId.unwrap(signerId)) == false) revert InvalidSession(signerId);
        $userOpPolicies.enable({
            signerId: signerId,
            sessionId: signerId.toUserOpPolicyId().toSessionId(),
            policyDatas: userOpPolicies,
            smartAccount: msg.sender,
            useRegistry: true
        });
    }

    function enableERC1271Policies(SignerId signerId, PolicyData[] memory erc1271Policies) public {
        if ($enabledSessions.contains(msg.sender, SignerId.unwrap(signerId)) == false) revert InvalidSession(signerId);
        $erc1271Policies.enable({
            signerId: signerId,
            sessionId: signerId.toErc1271PolicyId().toSessionId(),
            policyDatas: erc1271Policies,
            smartAccount: msg.sender,
            useRegistry: true
        });
    }

    function enableActionPolicies(SignerId signerId, ActionData[] memory actionPolicies) public {
        if ($enabledSessions.contains(msg.sender, SignerId.unwrap(signerId)) == false) revert InvalidSession(signerId);
        $actionPolicies.enable({
            signerId: signerId,
            actionPolicyDatas: actionPolicies,
            smartAccount: msg.sender,
            useRegistry: true
        });
    }

    function enableSessions(EnableSessions[] calldata sessions) public returns (SignerId[] memory signerIds) {
        uint256 length = sessions.length;
        signerIds = new SignerId[](length);
        for (uint256 i; i < length; i++) {
            EnableSessions calldata session = sessions[i];
            if (session.permissionEnableSig.length != 0) revert InvalidData();
            SignerId signerId = getSignerId(session.isigner, session.isignerInitData);
            $enabledSessions.add({ account: msg.sender, value: SignerId.unwrap(signerId) });
            _enableISigner({
                signerId: signerId,
                account: msg.sender,
                isigner: session.isigner,
                signerConfig: session.isignerInitData
            });

            $userOpPolicies.enable({
                signerId: signerId,
                sessionId: signerId.toUserOpPolicyId().toSessionId(),
                policyDatas: session.userOpPolicies,
                smartAccount: msg.sender,
                useRegistry: true
            });

            $erc1271Policies.enable({
                signerId: signerId,
                sessionId: signerId.toErc1271PolicyId().toSessionId(),
                policyDatas: session.erc1271Policies,
                smartAccount: msg.sender,
                useRegistry: true
            });

            $actionPolicies.enable({
                signerId: signerId,
                actionPolicyDatas: session.actions,
                smartAccount: msg.sender,
                useRegistry: true
            });
            signerIds[i] = signerId;
            emit SessionCreated(signerId, msg.sender);
        }
    }

    function removeSession(SignerId signerId) public {
        $userOpPolicies.policyList[signerId].disable(signerId.toUserOpPolicyId().toSessionId(), msg.sender);
        $erc1271Policies.policyList[signerId].disable(signerId.toErc1271PolicyId().toSessionId(), msg.sender);

        uint256 actionLength = $actionPolicies.enabledActionIds[signerId].length(msg.sender);
        for (uint256 i; i < actionLength; i++) {
            ActionId actionId = ActionId.wrap($actionPolicies.enabledActionIds[signerId].get(msg.sender, i));
            $actionPolicies.actionPolicies[actionId].policyList[signerId].disable(
                signerId.toSessionId(actionId), msg.sender
            );
        }

        $enabledSessions.remove({ account: msg.sender, value: SignerId.unwrap(signerId) });
        emit SessionRemoved(signerId, msg.sender);
    }

    /**
     * Initialize the module with the given data
     *
     * @param data The data to initialize the module with
     */
    function onInstall(bytes calldata data) external override {
        if (data.length == 0) return;

        EnableSessions[] calldata sessions;
        assembly ("memory-safe") {
            let dataPointer := add(data.offset, calldataload(data.offset))

            sessions.offset := add(dataPointer, 32)
            sessions.length := calldataload(dataPointer)
        }
        enableSessions(sessions);
    }

    /**
     * De-initialize the module with the given data
     */
    function onUninstall(bytes calldata /*data*/ ) external override {
        uint256 sessionIdsCnt = $enabledSessions.length({ account: msg.sender });

        for (uint256 i; i < sessionIdsCnt; i++) {
            SignerId sessionId = SignerId.wrap($enabledSessions.at({ account: msg.sender, index: i }));
            removeSession(sessionId);
        }
    }

    function isInitialized(address smartAccount) external view returns (bool) {
        uint256 sessionIdsCnt = $enabledSessions.length({ account: smartAccount });
        return sessionIdsCnt > 0;
    }

    function isModuleType(uint256 typeID) external pure override returns (bool) {
        return typeID == TYPE_VALIDATOR;
    }

    function getDigest(
        ISigner isigner,
        address account,
        EnableSessions memory data,
        SmartSessionMode mode
    )
        external
        view
        returns (bytes32)
    {
        uint256 nonce = $signerNonce[isigner][account];
        return isigner.digest(nonce, data, mode);
    }

    function getSignerId(ISigner isigner, bytes memory isignerInitData) public pure returns (SignerId signerId) {
        signerId = SignerId.wrap(keccak256(abi.encode(isigner, isignerInitData)));
    }

    function _isISignerSet(SignerId signerId, address account) internal view returns (bool) {
        return address($isigners[signerId][account].isigner) != address(0);
    }
}

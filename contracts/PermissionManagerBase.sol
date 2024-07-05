import "./DataTypes.sol";
import {
    AddressArrayMap4337 as AddressVec,
    Bytes32ArrayMap4337 as Bytes32Vec,
    ArrayMap4337Lib as AddressVecLib
} from "contracts/lib/ArrayMap4337Lib.sol";

import "./interfaces/ISigner.sol";
import { SentinelList4337Lib } from "sentinellist/SentinelList4337.sol";
import { Bytes32ArrayMap4337, ArrayMap4337Lib } from "./lib/ArrayMap4337Lib.sol";
import { ERC7579ValidatorBase, ERC7579ExecutorBase } from "modulekit/Modules.sol";
import { ConfigLib } from "./lib/ConfigLib.sol";
import { SignatureDecodeLib } from "./lib/SignatureDecodeLib.sol";

abstract contract PermissionManagerBase is ERC7579ValidatorBase {
    using ConfigLib for *;
    using SignatureDecodeLib for *;
    using SentinelList4337Lib for SentinelList4337Lib.SentinelList;
    using ArrayMap4337Lib for *;
    using ConfigLib for Policy;
    using ConfigLib for EnumerableActionPolicy;

    error InvalidISigner(ISigner isigner);

    Policy internal $userOpPolicies;
    Policy internal $erc1271Policies;
    EnumerableActionPolicy internal $actionPolicies;
    mapping(SignerId => mapping(address smartAccount => ISigner)) internal $isigners;

    function _enableISigner(SignerId signerId, address account, ISigner isigner, bytes memory initData) internal {
        if (!isigner.supportsInterface(type(ISigner).interfaceId)) {
            revert InvalidISigner(isigner);
        }

        $isigners[signerId][msg.sender] = isigner;

        isigner.initForAccount({ account: account, id: sessionId(signerId), initData: initData });
    }

    function enableUserOpPolicies(SignerId signerId, PolicyData[] memory userOpPolicies) public {
        $userOpPolicies.enable({ signerId: signerId, policyDatas: userOpPolicies, smartAccount: msg.sender });
    }

    function enableERC1271Policies(SignerId signerId, PolicyData[] memory erc1271Policies) public {
        $erc1271Policies.enable({ signerId: signerId, policyDatas: erc1271Policies, smartAccount: msg.sender });
    }

    function enableActionPolicies(SignerId signerId, ActionData[] memory actionPolicies) public {
        $actionPolicies.enable({ signerId: signerId, actionPolicyDatas: actionPolicies, smartAccount: msg.sender });
    }

    function removeSession(SignerId signerId) public {
        $userOpPolicies.policyList[signerId].disable(sessionId(signerId), msg.sender);
        $erc1271Policies.policyList[signerId].disable(sessionId(signerId), msg.sender);

        uint256 actionLength = $actionPolicies.enabledActionIds.length(msg.sender);
        for (uint256 i; i < actionLength; i++) {
            ActionId actionId = ActionId.wrap($actionPolicies.enabledActionIds.get(msg.sender, i));
            $actionPolicies.actionPolicies[actionId].policyList[signerId].disable(
                sessionId(signerId, actionId), msg.sender
            );
        }
    }

    function setSigner(SignerId signerId, ISigner signer, bytes memory initData) public {
        _enableISigner(signerId, msg.sender, signer, initData);
    }

    /**
     * Initialize the module with the given data
     *
     * @param data The data to initialize the module with
     */
    function onInstall(bytes calldata data) external override {
        if (data.length == 0) return;

        InstallSessions[] memory sessions = abi.decode(data, (InstallSessions[]));

        uint256 length = sessions.length;
        for (uint256 i; i < length; i++) {
            SignerId signerId = sessions[i].signerId;
            enableUserOpPolicies({ signerId: signerId, userOpPolicies: sessions[i].userOpPolicies });
            enableERC1271Policies({ signerId: signerId, erc1271Policies: sessions[i].erc1271Policies });
            enableActionPolicies({ signerId: signerId, actionPolicies: sessions[i].actions });
        }
    }

    /**
     * De-initialize the module with the given data
     *
     * @param data The data to de-initialize the module with
     */
    function onUninstall(bytes calldata data) external override { }

    function isInitialized(address smartAccount) external view returns (bool) { }

    function isModuleType(uint256 typeID) external pure override returns (bool) {
        return typeID == TYPE_VALIDATOR;
    }

    function install(InstallSessions[] memory sessions) public { }
}

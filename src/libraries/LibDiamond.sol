// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

library LibDiamond {
    bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");

    struct FacetAddressAndSelectorPosition {
        address facetAddress;
        uint16 selectorPosition;
    }

    struct DiamondStorage {
        // function selector => facet address and selector position in selectors array
        mapping(bytes4 => FacetAddressAndSelectorPosition) facetAddressAndSelectorPosition;
        bytes4[] selectors;
        // facet address => selectors
        mapping(address => bytes4[]) facetSelectors;
        // facet addresses
        address[] facetAddresses;
        // ERC-165 interface id => supported
        mapping(bytes4 => bool) supportedInterfaces;
        // owner
        address contractOwner;
        // pending owner for 2-step transfer
        address pendingOwner;
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut, address _init, bytes _calldata);

    error NotContractOwner(address sender, address owner);
    error NotPendingOwner(address sender, address pendingOwner);
    error NoSelectorsProvidedForFacetForCut(address facet);
    error CannotAddSelectorsToZeroAddress(bytes4[] selectors);
    error NoBytecodeAtAddress(address addr, string context);
    error CannotAddFunctionThatAlreadyExists(bytes4 selector);
    error CannotReplaceFunctionsFromFacetWithZeroAddress(bytes4[] selectors);
    error CannotReplaceImmutableFunction(bytes4 selector);
    error CannotReplaceFunctionWithTheSameFunctionFromTheSameFacet(bytes4 selector);
    error CannotReplaceFunctionThatDoesNotExist(bytes4 selector);
    error RemoveFacetAddressMustBeZeroAddress(address facet);
    error CannotRemoveFunctionThatDoesNotExist(bytes4 selector);
    error CannotRemoveImmutableFunction(bytes4 selector);
    error InitializationFunctionReverted(address init, bytes data);

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function setContractOwner(address _newOwner) internal {
        DiamondStorage storage ds = diamondStorage();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = _newOwner;
        ds.pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    function contractOwner() internal view returns (address owner_) {
        owner_ = diamondStorage().contractOwner;
    }

    function pendingOwner() internal view returns (address pending_) {
        pending_ = diamondStorage().pendingOwner;
    }

    function enforceIsContractOwner() internal view {
        DiamondStorage storage ds = diamondStorage();
        if (msg.sender != ds.contractOwner) {
            revert NotContractOwner(msg.sender, ds.contractOwner);
        }
    }

    function setPendingOwner(address _newOwner) internal {
        DiamondStorage storage ds = diamondStorage();
        ds.pendingOwner = _newOwner;
        emit OwnershipTransferStarted(ds.contractOwner, _newOwner);
    }

    function acceptOwnership() internal {
        DiamondStorage storage ds = diamondStorage();
        if (msg.sender != ds.pendingOwner) {
            revert NotPendingOwner(msg.sender, ds.pendingOwner);
        }
        setContractOwner(msg.sender);
    }

    function diamondCut(IDiamondCut.FacetCut[] memory _diamondCut, address _init, bytes memory _calldata) internal {
        for (uint256 facetIndex; facetIndex < _diamondCut.length; facetIndex++) {
            IDiamondCut.FacetCutAction action = _diamondCut[facetIndex].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                addFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                replaceFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Remove) {
                removeFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            }
        }
        emit DiamondCut(_diamondCut, _init, _calldata);
        initializeDiamondCut(_init, _calldata);
    }

    function addFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length == 0) {
            revert NoSelectorsProvidedForFacetForCut(_facetAddress);
        }
        DiamondStorage storage ds = diamondStorage();
        if (_facetAddress == address(0)) {
            revert CannotAddSelectorsToZeroAddress(_functionSelectors);
        }
        enforceHasContractCode(_facetAddress, "DiamondCut: Add facet has no code");
        // Add facet address if new
        if (ds.facetSelectors[_facetAddress].length == 0) {
            ds.facetAddresses.push(_facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            if (oldFacetAddress != address(0)) {
                revert CannotAddFunctionThatAlreadyExists(selector);
            }
            ds.facetAddressAndSelectorPosition[selector] = FacetAddressAndSelectorPosition(
                _facetAddress, uint16(ds.selectors.length)
            );
            ds.selectors.push(selector);
            ds.facetSelectors[_facetAddress].push(selector);
        }
    }

    function replaceFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length == 0) {
            revert NoSelectorsProvidedForFacetForCut(_facetAddress);
        }
        DiamondStorage storage ds = diamondStorage();
        if (_facetAddress == address(0)) {
            revert CannotReplaceFunctionsFromFacetWithZeroAddress(_functionSelectors);
        }
        enforceHasContractCode(_facetAddress, "DiamondCut: Replace facet has no code");
        // Add facet address if new
        if (ds.facetSelectors[_facetAddress].length == 0) {
            ds.facetAddresses.push(_facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            if (oldFacetAddress == address(this)) {
                revert CannotReplaceImmutableFunction(selector);
            }
            if (oldFacetAddress == _facetAddress) {
                revert CannotReplaceFunctionWithTheSameFunctionFromTheSameFacet(selector);
            }
            if (oldFacetAddress == address(0)) {
                revert CannotReplaceFunctionThatDoesNotExist(selector);
            }
            ds.facetAddressAndSelectorPosition[selector].facetAddress = _facetAddress;
            // Remove from old facet's selectors and add to new
            _removeSelectorFromFacetSelectors(ds, oldFacetAddress, selector);
            ds.facetSelectors[_facetAddress].push(selector);
            // Clean up old facet address if no selectors left
            _cleanUpFacetAddress(ds, oldFacetAddress);
        }
    }

    function removeFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length == 0) {
            revert NoSelectorsProvidedForFacetForCut(_facetAddress);
        }
        DiamondStorage storage ds = diamondStorage();
        if (_facetAddress != address(0)) {
            revert RemoveFacetAddressMustBeZeroAddress(_facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            FacetAddressAndSelectorPosition memory oldFacetAndPosition =
                ds.facetAddressAndSelectorPosition[selector];
            if (oldFacetAndPosition.facetAddress == address(0)) {
                revert CannotRemoveFunctionThatDoesNotExist(selector);
            }
            if (oldFacetAndPosition.facetAddress == address(this)) {
                revert CannotRemoveImmutableFunction(selector);
            }
            // Replace selector with last selector, then pop
            uint256 lastSelectorIndex = ds.selectors.length - 1;
            uint16 selectorPosition = oldFacetAndPosition.selectorPosition;
            if (selectorPosition != lastSelectorIndex) {
                bytes4 lastSelector = ds.selectors[lastSelectorIndex];
                ds.selectors[selectorPosition] = lastSelector;
                ds.facetAddressAndSelectorPosition[lastSelector].selectorPosition = selectorPosition;
            }
            ds.selectors.pop();
            delete ds.facetAddressAndSelectorPosition[selector];
            // Remove from facet's selectors
            _removeSelectorFromFacetSelectors(ds, oldFacetAndPosition.facetAddress, selector);
            _cleanUpFacetAddress(ds, oldFacetAndPosition.facetAddress);
        }
    }

    function _removeSelectorFromFacetSelectors(
        DiamondStorage storage ds,
        address _facetAddress,
        bytes4 _selector
    ) private {
        bytes4[] storage facetSels = ds.facetSelectors[_facetAddress];
        for (uint256 i; i < facetSels.length; i++) {
            if (facetSels[i] == _selector) {
                facetSels[i] = facetSels[facetSels.length - 1];
                facetSels.pop();
                break;
            }
        }
    }

    function _cleanUpFacetAddress(DiamondStorage storage ds, address _facetAddress) private {
        if (ds.facetSelectors[_facetAddress].length == 0) {
            // Remove from facetAddresses array
            for (uint256 i; i < ds.facetAddresses.length; i++) {
                if (ds.facetAddresses[i] == _facetAddress) {
                    ds.facetAddresses[i] = ds.facetAddresses[ds.facetAddresses.length - 1];
                    ds.facetAddresses.pop();
                    break;
                }
            }
        }
    }

    function initializeDiamondCut(address _init, bytes memory _calldata) internal {
        if (_init == address(0)) {
            return;
        }
        enforceHasContractCode(_init, "DiamondCut: _init address has no code");
        (bool success, bytes memory error) = _init.delegatecall(_calldata);
        if (!success) {
            if (error.length > 0) {
                assembly {
                    let returndata_size := mload(error)
                    revert(add(32, error), returndata_size)
                }
            } else {
                revert InitializationFunctionReverted(_init, _calldata);
            }
        }
    }

    function enforceHasContractCode(address _contract, string memory _errorMessage) internal view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contract)
        }
        if (contractSize == 0) {
            revert NoBytecodeAtAddress(_contract, _errorMessage);
        }
    }
}

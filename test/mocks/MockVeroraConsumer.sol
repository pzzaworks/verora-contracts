// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VeroraConsumer} from "../../src/VeroraConsumer.sol";

/**
 * @title MockVeroraConsumer
 * @notice Simple consumer mock that stores the last fulfilled result
 */
contract MockVeroraConsumer is VeroraConsumer {
    bytes32 public lastRequestId;
    bytes public lastResult;
    uint256 public fulfillCount;
    bytes32 public lastFailedRequestId;

    constructor(address queryConsumer_) VeroraConsumer(queryConsumer_) {}

    function makeRequest(string memory queryType, bytes memory queryData, uint256 deadline, bytes32[] memory agents)
        external
        payable
        returns (bytes32)
    {
        return _requestQuery(queryType, queryData, deadline, agents);
    }

    function _onQueryFulfilled(bytes32 requestId, bytes calldata result) internal override {
        lastRequestId = requestId;
        lastResult = result;
        fulfillCount++;
    }

    function _onQueryFailed(bytes32 requestId) internal override {
        lastFailedRequestId = requestId;
    }

    function isPending(bytes32 requestId) external view returns (bool) {
        return _pendingRequests[requestId];
    }
}

/**
 * @title RevertingConsumer
 * @notice Consumer mock that always reverts in the callback
 */
contract RevertingConsumer is VeroraConsumer {
    error AlwaysReverts();

    constructor(address queryConsumer_) VeroraConsumer(queryConsumer_) {}

    function makeRequest(string memory queryType, bytes memory queryData, uint256 deadline, bytes32[] memory agents)
        external
        payable
        returns (bytes32)
    {
        return _requestQuery(queryType, queryData, deadline, agents);
    }

    function _onQueryFulfilled(bytes32, bytes calldata) internal pure override {
        revert AlwaysReverts();
    }
}

/**
 * @title ReturndataBombConsumer
 * @notice Consumer mock that reverts with a huge payload to try to exhaust the caller's gas on copy
 */
contract ReturndataBombConsumer is VeroraConsumer {
    uint256 public constant BOMB_SIZE = 200_000;

    constructor(address queryConsumer_) VeroraConsumer(queryConsumer_) {}

    function makeRequest(string memory queryType, bytes memory queryData, uint256 deadline, bytes32[] memory agents)
        external
        payable
        returns (bytes32)
    {
        return _requestQuery(queryType, queryData, deadline, agents);
    }

    function _onQueryFulfilled(bytes32, bytes calldata) internal pure override {
        assembly {
            revert(0, BOMB_SIZE)
        }
    }
}

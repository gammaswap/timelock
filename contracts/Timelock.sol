// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

contract TimeLock {
    error NotOwnerError();
    error AlreadyQueuedError(bytes32 txId);
    error AlreadyExecutedError(bytes32 txId);
    error TimestampBadRangeError(uint256 blockTimestamp, uint256 timestamp_from, uint256 timestamp_to);
    error NotQueuedError(bytes32 txId);
    error TimestampNotPassedError(uint256 blockTimestmap, uint256 timestampFrom);
    error TimestampExpiredError(uint256 blockTimestamp, uint256 timestampTo);
    error TxFailedError();

    event Queue(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        string func,
        uint256 timestamp_from,
        uint256 timestamp_to
    );
    event EmergencyQueue(
        bytes32 indexed txid,
        address indexed target,
        string func
    );
    event Execute(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        string func,
        bytes data,
        uint256 timestamp
    );
    event EmergencyExecute(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        string func,
        bytes data,
        uint256 timestamp
    );
    event Cancel(bytes32 indexed txId);
    event CancelEmergency(address target, string func);

    address public owner;
    // tx id => queued/executed
    // 0 - not queued
    // 1 - queued
    // >1 - executed timestamp
    mapping(bytes32 => uint256) public queued;
    mapping(bytes32 => bool) public emergencyQueued;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwnerError();
        }
        _;
    }

    receive() external payable {}

    function getTxId(
        address _target,
        uint256 _value,
        string calldata _func,
        uint256 _timestamp_from,
        uint256 _timestamp_to
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(_target, _value, _func, _timestamp_from, _timestamp_to));
    }

    function getEmergencyTxId(
        address _target,
        string calldata _func
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(_target, _func));
    }

    /**
     * @param _target Address of contract or account to call
     * @param _value Amount of ETH to send
     * @param _func Function signature, for example "foo(address,uint256)"
     * @param _timestamp_from From timestamp of range when the transaction can be executed.
     * @param _timestamp_to To timestamp of range when the transaction can be executed.
     */
    function queue(
        address _target,
        uint256 _value,
        string calldata _func,
        uint256 _timestamp_from,
        uint256 _timestamp_to
    ) external onlyOwner returns (bytes32 txId) {
        txId = getTxId(_target, _value, _func, _timestamp_from, _timestamp_to);
        if (queued[txId] == 1) {
            revert AlreadyQueuedError(txId);
        } else if (queued[txId] > 1) {
            revert AlreadyExecutedError(txId);
        }
        // ---|------------|---------------|-------
        //  block    block + from     block + to
        if (
            _timestamp_from >= _timestamp_to || _timestamp_from <= block.timestamp
        ) {
            revert TimestampBadRangeError(block.timestamp, _timestamp_from, _timestamp_to);
        }

        queued[txId] = 1;

        emit Queue(txId, _target, _value, _func, _timestamp_from, _timestamp_to);
    }

    // Queue function signature itself without timestamp range
    function queueEmergency(
        address _target,
        string calldata _func
    ) external onlyOwner returns (bytes32 txId) {
        txId = getEmergencyTxId(_target, _func);
        if (emergencyQueued[txId]) {
            revert AlreadyQueuedError(txId);
        }

        emergencyQueued[txId] = true;

        emit EmergencyQueue(txId, _target, _func);
    }

    function execute(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp_from,
        uint256 _timestamp_to
    ) external payable onlyOwner returns (bytes memory) {
        bytes32 txId = getTxId(_target, _value, _func, _timestamp_from, _timestamp_to);
        if (queued[txId] == 0) {
            revert NotQueuedError(txId);
        } else if (queued[txId] > 1) {
            revert AlreadyExecutedError(txId);
        }
        // ------|----------------|------------|-------
        //  block + from        block     block + to
        uint256 timestamp = block.timestamp;
        if (timestamp < _timestamp_from) {
            revert TimestampNotPassedError(timestamp, _timestamp_from);
        }
        if (timestamp > _timestamp_to) {
            revert TimestampExpiredError(timestamp, _timestamp_to);
        }

        queued[txId] = timestamp;

        // prepare data
        bytes memory data;
        if (bytes(_func).length > 0) {
            // data = func selector + _data
            data = abi.encodePacked(bytes4(keccak256(bytes(_func))), _data);
        } else {
            // call fallback with data
            data = _data;
        }

        // call target
        (bool ok, bytes memory res) = _target.call{value: _value}(data);
        if (!ok) {
            revert TxFailedError();
        }

        emit Execute(txId, _target, _value, _func, _data, timestamp);

        return res;
    }

    function executeEmergency(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data
    ) external payable onlyOwner returns (bytes memory) {
        bytes32 txId = getEmergencyTxId(_target,  _func);
        if (!emergencyQueued[txId]) {
            revert NotQueuedError(txId);
        }

        // prepare data
        bytes memory data;
        if (bytes(_func).length > 0) {
            // data = func selector + _data
            data = abi.encodePacked(bytes4(keccak256(bytes(_func))), _data);
        } else {
            // call fallback with data
            data = _data;
        }

        // call target
        (bool ok, bytes memory res) = _target.call{value: _value}(data);
        if (!ok) {
            revert TxFailedError();
        }

        emit EmergencyExecute(txId, _target, _value, _func, _data, block.timestamp);

        return res;
    }

    function cancel(bytes32 _txId) external onlyOwner {
        if (queued[_txId] == 0) {
            revert NotQueuedError(_txId);
        } else if (queued[_txId] > 1) {
            revert AlreadyExecutedError(_txId);
        }

        queued[_txId] = 0;

        emit Cancel(_txId);
    }

    // Unqueue function signature itself
    function cancelEmergency(
        address _target,
        string calldata _func
    ) external onlyOwner {
        bytes32 txId = getEmergencyTxId(_target, _func);
        if (!emergencyQueued[txId]) {
            revert NotQueuedError(txId);
        }

        emergencyQueued[txId] = false;

        emit CancelEmergency(_target, _func);
    }
}

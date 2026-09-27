// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Counter {
    error AlreadyInitialized();
    error Unauthorized();

    enum InitializationState {
        Uninitialized,
        Initialized,
        Disabled
    }

    InitializationState private _initializationState;
    address public owner;
    uint256 public count;

    constructor() {
        // Constructors do not run in clones, whose storage starts uninitialized.
        _initializationState = InitializationState.Disabled;
    }

    function initialize(address owner_) external {
        if (_initializationState != InitializationState.Uninitialized) revert AlreadyInitialized();
        _initializationState = InitializationState.Initialized;
        owner = owner_;
    }

    function increment() external {
        if (_initializationState != InitializationState.Initialized || msg.sender != owner) revert Unauthorized();
        ++count;
    }
}

contract CloneFactory {
    error DeploymentFailed();

    event CounterCreated(address indexed owner, bytes32 indexed userSalt, address clone);

    address public immutable implementation;

    constructor() {
        implementation = address(new Counter());
    }

    function createCounter(bytes32 userSalt) external returns (address clone) {
        bytes32 salt = keccak256(abi.encode(msg.sender, userSalt));
        bytes memory initCode = _initCode();
        assembly ("memory-safe") {
            clone := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (clone == address(0)) revert DeploymentFailed();

        Counter(clone).initialize(msg.sender);
        emit CounterCreated(msg.sender, userSalt, clone);
    }

    function predict(address creator, bytes32 userSalt) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(creator, userSalt));
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(_initCode())));
        return address(uint160(uint256(hash)));
    }

    function _initCode() private view returns (bytes memory) {
        // Ten-byte creation prefix followed by the standard 45-byte EIP-1167 runtime.
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3", hex"363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3"
        );
    }
}

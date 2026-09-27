// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Counter, CloneFactory} from "../src/CloneFactory.sol";

interface Vm {
    function prank(address msgSender) external;
    function expectRevert(bytes4 revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter) external;
}

contract CloneFactoryTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    CloneFactory private factory;

    event CounterCreated(address indexed owner, bytes32 indexed userSalt, address clone);

    function setUp() public {
        factory = new CloneFactory();
    }

    function testFuzzPredictionMatchesDeployment(address creator, bytes32 userSalt) public {
        _assertPredictionAndRuntime(creator, userSalt);
    }

    function testZeroAndMaximumCreatorsAndSalts() public {
        address maximum = address(type(uint160).max);
        bytes32 maximumSalt = bytes32(type(uint256).max);
        _assertPredictionAndRuntime(address(0), bytes32(0));
        _assertPredictionAndRuntime(address(0), maximumSalt);
        _assertPredictionAndRuntime(maximum, bytes32(0));
        _assertPredictionAndRuntime(maximum, maximumSalt);
    }

    function testFuzzSameCreatorAndSaltCannotBeReused(address creator, bytes32 userSalt) public {
        Counter counter = _create(creator, userSalt);
        vm.prank(creator);
        counter.increment();

        vm.expectRevert(CloneFactory.DeploymentFailed.selector);
        vm.prank(creator);
        factory.createCounter(userSalt);

        require(counter.owner() == creator, "duplicate changed owner");
        require(counter.count() == 1, "duplicate changed count");
        require(factory.predict(creator, userSalt) == address(counter), "prediction changed after deployment");
    }

    function testFuzzDifferentCreatorsCanReuseSalt(address creator, bytes32 userSalt) public {
        address otherCreator = address(uint160(creator) ^ uint160(1));
        address reservedForCreator = factory.predict(creator, userSalt);
        Counter other = _create(otherCreator, userSalt);

        require(address(other) != reservedForCreator, "caller stole another caller's address");
        require(reservedForCreator.code.length == 0, "another caller deployed at reserved address");

        Counter counter = _create(creator, userSalt);
        require(address(counter) == reservedForCreator, "creator's address changed");
        require(address(other) == factory.predict(otherCreator, userSalt), "other prediction mismatch");
        require(counter.owner() == creator, "wrong creator owner");
        require(other.owner() == otherCreator, "wrong other owner");
    }

    function testFuzzCloneCannotBeReinitialized(address creator, address caller, bytes32 userSalt) public {
        Counter counter = _create(creator, userSalt);
        vm.prank(creator);
        counter.increment();

        vm.expectRevert(Counter.AlreadyInitialized.selector);
        vm.prank(caller);
        counter.initialize(caller);

        // Even the original owner cannot initialize it a second time.
        vm.expectRevert(Counter.AlreadyInitialized.selector);
        vm.prank(creator);
        counter.initialize(creator);

        require(counter.owner() == creator, "reinitialization changed owner");
        require(counter.count() == 1, "reinitialization changed count");
    }

    function testFuzzImplementationIsLocked(address caller, address proposedOwner) public {
        Counter implementation = Counter(factory.implementation());
        require(address(implementation).code.length > 0, "implementation missing");

        vm.expectRevert(Counter.AlreadyInitialized.selector);
        vm.prank(caller);
        implementation.initialize(proposedOwner);

        vm.expectRevert(Counter.Unauthorized.selector);
        vm.prank(caller);
        implementation.increment();

        require(implementation.count() == 0, "implementation count changed");
        require(implementation.owner() == address(0), "implementation owner changed");
    }

    function testImplementationIsLockedForZeroCaller() public {
        testFuzzImplementationIsLocked(address(0), ALICE);
    }

    function testFuzzOnlyOwnerCanIncrement(address creator, bytes32 userSalt, uint8 increments) public {
        Counter counter = _create(creator, userSalt);
        address other = address(uint160(creator) ^ uint160(1));

        vm.expectRevert(Counter.Unauthorized.selector);
        vm.prank(other);
        counter.increment();
        require(counter.count() == 0, "unauthorized caller incremented");

        for (uint256 i; i < increments; ++i) {
            vm.prank(creator);
            counter.increment();
        }
        require(counter.count() == increments, "incorrect owner increment count");

        vm.expectRevert(Counter.Unauthorized.selector);
        vm.prank(other);
        counter.increment();
        require(counter.count() == increments, "unauthorized call changed existing count");
    }

    function testClonesKeepSeparateStorageAndOwners() public {
        Counter aliceCounter = _create(ALICE, bytes32(0));
        Counter bobCounter = _create(BOB, bytes32(0));
        Counter anotherAliceCounter = _create(ALICE, bytes32(uint256(1)));

        vm.prank(ALICE);
        aliceCounter.increment();
        vm.prank(ALICE);
        aliceCounter.increment();
        vm.prank(BOB);
        bobCounter.increment();

        require(aliceCounter.count() == 2, "alice count not isolated");
        require(bobCounter.count() == 1, "bob count not isolated");
        require(anotherAliceCounter.count() == 0, "same-owner count not isolated");
        require(aliceCounter.owner() == ALICE, "alice owner not isolated");
        require(bobCounter.owner() == BOB, "bob owner not isolated");
        require(anotherAliceCounter.owner() == ALICE, "second alice owner incorrect");
        require(Counter(factory.implementation()).count() == 0, "implementation storage changed");

        vm.expectRevert(Counter.Unauthorized.selector);
        vm.prank(ALICE);
        bobCounter.increment();
        vm.expectRevert(Counter.Unauthorized.selector);
        vm.prank(BOB);
        aliceCounter.increment();

        vm.prank(ALICE);
        anotherAliceCounter.increment();
        require(aliceCounter.count() == 2, "same owner's clones share storage");
        require(bobCounter.count() == 1, "cross-owner call changed count");
        require(anotherAliceCounter.count() == 1, "second alice counter cannot increment");
    }

    function testFuzzEmitsCounterCreated(address creator, bytes32 userSalt) public {
        address predicted = factory.predict(creator, userSalt);
        vm.expectEmit(true, true, false, true, address(factory));
        emit CounterCreated(creator, userSalt, predicted);
        Counter counter = _create(creator, userSalt);
        require(address(counter) == predicted, "event address mismatch");
        require(counter.owner() == creator, "clone not initialized before return");
    }

    function _create(address creator, bytes32 userSalt) private returns (Counter) {
        vm.prank(creator);
        return Counter(factory.createCounter(userSalt));
    }

    function _assertPredictionAndRuntime(address creator, bytes32 userSalt) private {
        address implementation = factory.implementation();
        bytes memory expectedRuntime =
            abi.encodePacked(hex"363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3");
        bytes32 initCodeHash = keccak256(abi.encodePacked(hex"3d602d80600a3d3981f3", expectedRuntime));
        address expected = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(factory), keccak256(abi.encode(creator, userSalt)), initCodeHash
                        )
                    )
                )
            )
        );
        address predicted = factory.predict(creator, userSalt);
        require(predicted == expected, "incorrect CREATE2 formula or salt encoding");
        require(predicted.code.length == 0, "prediction deployed code");

        Counter counter = _create(creator, userSalt);
        require(address(counter) == predicted, "prediction does not match deployment");
        require(counter.owner() == creator, "clone initialized with wrong owner");
        require(counter.count() == 0, "clone count not initially zero");
        require(address(counter).code.length == 45, "runtime is not 45 bytes");
        require(keccak256(address(counter).code) == keccak256(expectedRuntime), "incorrect EIP-1167 runtime");
        require(factory.implementation() == implementation, "factory implementation changed");
    }
}

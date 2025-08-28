// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Moveo} from "../src/Moveo.sol";

contract MoveoTest is Test {
    Moveo public moveo;

    address public immutable owner = makeAddr("owner");
    uint256 public immutable user0_pk = uint256(keccak256("user0-private-key"));
    address public immutable user0 = vm.addr(user0_pk);
    uint256 public immutable user1_pk = uint256(keccak256("user1-private-key"));
    address public immutable user1 = vm.addr(user1_pk);
    uint256 public immutable user2_pk = uint256(keccak256("user2-private-key"));
    address public immutable user2 = vm.addr(user2_pk);

    function setUp() public {
        moveo = new Moveo(owner);
        moveo.setNumber(0);
    }

    function test_Increment() public {
        moveo.increment();
        assertEq(moveo.number(), 1);
    }

    function testFuzz_SetNumber(uint256 x) public {
        moveo.setNumber(x);
        assertEq(moveo.number(), x);
    }
}

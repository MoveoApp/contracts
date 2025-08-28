// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {CREATE3Factory} from "create3-factory/src/CREATE3Factory.sol";
import {Script, console2} from "forge-std/Script.sol";
import {Moveo} from "../src/Moveo.sol";

contract DeployMoveoScript is Script {
    bytes32 salt = keccak256(abi.encodePacked(vm.envString("SALT")));
    address owner = vm.envAddress("OWNER");
    uint256 ownerPrivateKey = vm.envUint("OWNER_PRIVATE_KEY");
    address create3Factory = vm.envAddress("CREATE3_FACTORY");

    Moveo public moveo;

    function run() external {
        vm.startBroadcast(ownerPrivateKey);

        CREATE3Factory factory;
        if (create3Factory == address(0)) {
            console2.log("Deploying create3 factory...");
            factory = new CREATE3Factory();
            console2.log("Create3 factory deployed: ", address(factory));
        } else {
            console2.log("Reusing existing create3 factory");
            factory = CREATE3Factory(create3Factory);
        }

        console2.log("Deploying Moveo...");
        address moveoAddr =
            factory.deploy(salt, abi.encodePacked(type(Moveo).creationCode, abi.encode(owner)));
        console2.log("Moveo deployed: ", moveoAddr);

        vm.stopBroadcast();
    }
}

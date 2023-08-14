// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {VotingEscrowHookImplementation} from "./VotingEscrowHookImplementation.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";

contract VotingEscrowHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    int24 constant MAX_TICK_SPACING = 32767;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    TestERC20 token0;
    TestERC20 token1;
    PoolManager manager;
    VotingEscrowHookImplementation votingEscrowHook = VotingEscrowHookImplementation(
        address(uint160(Hooks.BEFORE_MODIFY_POSITION_FLAG | Hooks.AFTER_MODIFY_POSITION_FLAG))
    );
    PoolKey key;
    PoolId id;

    PoolModifyPositionTest modifyPositionRouter;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
        manager = new PoolManager(500000);

        vm.record();
        VotingEscrowHookImplementation impl =
            new VotingEscrowHookImplementation(manager, address(token0), "veToken", "veTKN", votingEscrowHook);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(votingEscrowHook), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(votingEscrowHook), slot, vm.load(address(impl), slot));
            }
        }
        key = PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, MAX_TICK_SPACING, votingEscrowHook
        );
        id = key.toId();
        votingEscrowHook.setPoolId(id);

        modifyPositionRouter = new PoolModifyPositionTest(manager);

        token0.approve(address(votingEscrowHook), type(uint256).max);
        token1.approve(address(votingEscrowHook), type(uint256).max);
        token0.approve(address(modifyPositionRouter), type(uint256).max);
        token1.approve(address(modifyPositionRouter), type(uint256).max);
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        manager.initialize(key, SQRT_RATIO_1_1);
    }
}

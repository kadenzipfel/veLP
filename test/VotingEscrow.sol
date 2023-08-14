// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {VotingEscrowImplementation} from "./VotingEscrowImplementation.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";

contract VotingEscrowTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    int24 constant MAX_TICK_SPACING = 32767;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    TestERC20Decimals token0;
    TestERC20Decimals token1;
    PoolManager manager;
    VotingEscrowImplementation votingEscrow = VotingEscrowImplementation(
        address(
            uint160(Hooks.BEFORE_MODIFY_POSITION_FLAG | Hooks.AFTER_MODIFY_POSITION_FLAG | Hooks.AFTER_INITIALIZE_FLAG)
        )
    );
    PoolKey key;
    PoolId id;

    PoolModifyPositionTest modifyPositionRouter;

    function setUp() public {
        token0 = new TestERC20Decimals(2**128);
        token1 = new TestERC20Decimals(2**128);

        if (uint256(uint160(address(token0))) > uint256(uint160(address(token1)))) {
            TestERC20Decimals token0_ = token1;
            token1 = token0;
            token0 = token0_;
        }

        manager = new PoolManager(500000);

        vm.record();
        VotingEscrowImplementation impl =
            new VotingEscrowImplementation(manager, address(token0), "veToken", "veTKN", votingEscrow);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(votingEscrow), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(votingEscrow), slot, vm.load(address(impl), slot));
            }
        }
        key = PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, MAX_TICK_SPACING, votingEscrow
        );
        id = key.toId();

        modifyPositionRouter = new PoolModifyPositionTest(manager);

        token0.approve(address(votingEscrow), type(uint256).max);
        token1.approve(address(votingEscrow), type(uint256).max);
        token0.approve(address(modifyPositionRouter), type(uint256).max);
        token1.approve(address(modifyPositionRouter), type(uint256).max);
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        manager.initialize(key, SQRT_RATIO_1_1);
    }

    function testAfterInitializeState() public {
        manager.initialize(key, SQRT_RATIO_2_1);
        assertEq(PoolId.unwrap(votingEscrow.poolId()), PoolId.unwrap(id));
    }
}

contract TestERC20Decimals is TestERC20 {
    constructor(uint256 amountToMint) TestERC20(amountToMint) {}

    function decimals() public pure returns (uint8) {
        return 18;
    }
}
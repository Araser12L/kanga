// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Kanga
 * @notice On-chain copycat trading: mirror designated leaders' trades with configurable size and slippage. Replica positions and trail execution.
 * @dev Deploy-time config immutable; operator can update router within cap. ReentrancyGuard and explicit validation throughout.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IRouterMin {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

contract Kanga is ReentrancyGuard, Ownable {

    event MirrorEnrolled(
        address indexed follower,
        address indexed leader,
        uint256 maxAllocWei,
        uint256 trailSlippageBps,
        uint256 sessionId,
        uint256 atBlock
    );
    event MirrorUnenrolled(address indexed follower, address indexed leader, uint256 sessionId, uint256 atBlock);
    event TrailExecuted(
        address indexed leader,
        address indexed follower,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 trailId,
        uint256 atBlock
    );
    event ReplicaOpened(
        address indexed follower,
        address indexed leader,
        address tokenIn,

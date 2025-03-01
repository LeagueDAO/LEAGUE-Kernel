// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.7.6;

import "../interfaces/IKernel.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract MulticallMock {
    using SafeMath for uint256;

    IKernel kernel;
    IERC20 leag;

    constructor(address _kernel, address _leag) {
        kernel = IKernel(_kernel);
        leag = IERC20(_leag);
    }

    function multiDelegate(uint256 amount, address user1, address user2) public {
        leag.approve(address(kernel), amount);

        kernel.deposit(amount);
        kernel.delegate(user1);
        kernel.delegate(user2);
        kernel.delegate(user1);
    }

    function multiDeposit(uint256 amount) public {
        leag.approve(address(kernel), amount.mul(3));

        kernel.deposit(amount);
        kernel.deposit(amount);
        kernel.deposit(amount);
    }
}

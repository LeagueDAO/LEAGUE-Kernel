// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.7.6;

import "../interfaces/ISupernova.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract MulticallMock {
    using SafeMath for uint256;

    ISupernova supernova;
    IERC20 entr;

    constructor(address _supernova, address _entr) {
        supernova = ISupernova(_supernova);
        entr = IERC20(_entr);
    }

    function multiDelegate(uint256 amount, address user1, address user2) public {
        entr.approve(address(supernova), amount);

        supernova.deposit(amount);
        supernova.delegate(user1);
        supernova.delegate(user2);
        supernova.delegate(user1);
    }

    function multiDeposit(uint256 amount) public {
        entr.approve(address(supernova), amount.mul(3));

        supernova.deposit(amount);
        supernova.deposit(amount);
        supernova.deposit(amount);
    }
}

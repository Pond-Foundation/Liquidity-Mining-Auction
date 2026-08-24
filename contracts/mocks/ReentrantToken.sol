// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAuction {
    function exit() external;
    function deposit(uint256 amount) external;
}

/// A malicious 18-decimal ERC20 that attempts to re-enter the auction from
/// inside `transfer` — used to prove the `nonReentrant` guard holds.
contract ReentrantToken {
    string public constant name = "Reentrant";
    string public constant symbol = "RE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    IAuction public target;
    bool public attack;
    uint8 public mode; // 0 = re-enter exit(), 1 = re-enter deposit()

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function setAttack(IAuction _t, bool _on, uint8 _mode) external { target = _t; attack = _on; mode = _mode; }

    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function transfer(address to, uint256 amount) external returns (bool) {
        _maybeReenter();
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address f, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amount;
        _maybeReenter();
        _transfer(f, to, amount);
        return true;
    }

    function _maybeReenter() internal {
        if (attack && address(target) != address(0)) {
            attack = false; // one shot
            if (mode == 0) target.exit();
            else target.deposit(1);
        }
    }

    function _transfer(address f, address to, uint256 amount) internal {
        require(balanceOf[f] >= amount, "balance");
        balanceOf[f] -= amount;
        balanceOf[to] += amount;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ERC20 mock where an admin can freeze addresses, like USDC/USDT blacklists. Frozen addresses can neither send nor receive.
contract FreezableERC20 {
	address public immutable admin;
	mapping(address => bool) public frozen;
	string public name;
	string public symbol;
	uint8 public immutable decimals;
	uint256 public totalSupply;

	mapping(address => uint256) public balanceOf;
	mapping(address => mapping(address => uint256)) public allowance;

	event Transfer(address indexed from, address indexed to, uint256 value);
	event Approval(address indexed owner, address indexed spender, uint256 value);
	event Frozen(address indexed account);
	event Unfrozen(address indexed account);

	constructor(string memory _name, string memory _symbol, uint8 _decimals) {
		name = _name;
		symbol = _symbol;
		decimals = _decimals;
		admin = msg.sender;
	}

	function freeze(address account) external {
		require(msg.sender == admin, "only admin can freeze");
		frozen[account] = true;
		emit Frozen(account);
	}

	function unfreeze(address account) external {
		require(msg.sender == admin, "only admin can unfreeze");
		frozen[account] = false;
		emit Unfrozen(account);
	}

	function transfer(address to, uint256 amount) external returns (bool) {
		_transfer(msg.sender, to, amount);
		return true;
	}

	function approve(address spender, uint256 amount) external returns (bool) {
		allowance[msg.sender][spender] = amount;
		emit Approval(msg.sender, spender, amount);
		return true;
	}

	function transferFrom(address from, address to, uint256 amount) external returns (bool) {
		uint256 allowed = allowance[from][msg.sender];
		require(allowed >= amount, "ERC20: insufficient allowance");
		if (allowed != type(uint256).max) {
			allowance[from][msg.sender] = allowed - amount;
			emit Approval(from, msg.sender, allowance[from][msg.sender]);
		}
		_transfer(from, to, amount);
		return true;
	}

	function mint(address to, uint256 amount) external {
		require(to != address(0), "ERC20: mint to zero address");
		totalSupply += amount;
		balanceOf[to] += amount;
		emit Transfer(address(0), to, amount);
	}

	function _transfer(address from, address to, uint256 amount) internal {
		require(to != address(0), "ERC20: transfer to zero address");
		require(!frozen[from], "ERC20: sender is frozen");
		require(!frozen[to], "ERC20: recipient is frozen");
		uint256 fromBal = balanceOf[from];
		require(fromBal >= amount, "ERC20: transfer amount exceeds balance");
		unchecked {
			balanceOf[from] = fromBal - amount;
			balanceOf[to] += amount;
		}
		emit Transfer(from, to, amount);
	}
}


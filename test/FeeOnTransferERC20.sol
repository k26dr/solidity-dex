// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ERC20 mock that burns a percentage of every transfer, so the recipient receives less than the requested amount.
// Fee is in basis points (100 = 1%) and can be changed mid-test with setFee.
contract FeeOnTransferERC20 {
	string public name;
	string public symbol;
	uint8 public immutable decimals;
	uint256 public totalSupply;
	uint256 public feeBasisPoints;

	mapping(address => uint256) public balanceOf;
	mapping(address => mapping(address => uint256)) public allowance;

	event Transfer(address indexed from, address indexed to, uint256 value);
	event Approval(address indexed owner, address indexed spender, uint256 value);

	constructor(string memory _name, string memory _symbol, uint8 _decimals, uint256 _feeBasisPoints) {
		require(_feeBasisPoints <= 10000, "fee over 100%");
		name = _name;
		symbol = _symbol;
		decimals = _decimals;
		feeBasisPoints = _feeBasisPoints;
	}

	function setFee(uint256 _feeBasisPoints) external {
		require(_feeBasisPoints <= 10000, "fee over 100%");
		feeBasisPoints = _feeBasisPoints;
	}

	// Amount the recipient actually receives when `amount` is sent
	function amountAfterFee(uint256 amount) public view returns (uint256) {
		return amount - amount * feeBasisPoints / 10000;
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
		uint256 fromBal = balanceOf[from];
		require(fromBal >= amount, "ERC20: transfer amount exceeds balance");
		uint256 received = amountAfterFee(amount);
		uint256 fee = amount - received;
		unchecked {
			balanceOf[from] = fromBal - amount;
			balanceOf[to] += received;
			totalSupply -= fee;
		}
		emit Transfer(from, to, received);
		if (fee > 0) emit Transfer(from, address(0), fee);
	}
}

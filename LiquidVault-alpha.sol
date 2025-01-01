// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract LiquidVault is Ownable, ReentrancyGuard {
    IERC20 public immutable vaultToken;
    IERC20 public immutable feeToken;
    address public immutable destinationAddress;
    
    uint256 public constant REQUIRED_DEPOSIT = 10_000_000_000; // 10 billion
    uint256 public constant DEDUCTION_RATE = 100;
    uint256 public constant MINIMUM_BALANCE = 1_000_000; // 1 million
    uint256 public constant ELIGIBILITY_THRESHOLD = 5_000_000_000; // 5 billion
    uint256 public constant WINDOW_SIZE = 14326;
    uint256 public constant CLAIM_DEADLINE_MULTIPLIER = 2;
    
    struct Vault {
        uint256 balance;
        uint256 depositBlock;
        uint256 lastDeductionBlock;
    }
    
    struct FeeWindow {
        uint256 totalFees;
        uint256 totalEligibleVaults;
        mapping(address => bool) hasClaimed;
    }
    
    // User => Vault ID => Vault
    mapping(address => mapping(uint256 => Vault)) public vaults;
    mapping(address => uint256) public userVaultCount;
    
    // Window ID => FeeWindow
    mapping(uint256 => FeeWindow) public feeWindows;
    
    event VaultCreated(address indexed user, uint256 indexed vaultId, uint256 amount);
    event TokensWithdrawn(address indexed user, uint256 indexed vaultId, uint256 amount);
    event FeesClaimed(address indexed user, uint256 indexed windowId, uint256 amount);
    event DeductionsCollected(uint256 amount);
    event FeeDeposited(uint256 indexed windowId, uint256 amount);
    
    constructor(
        address _vaultToken,
        address _feeToken,
        address _destinationAddress
    ) {
        require(_vaultToken != address(0), "Invalid vault token");
        require(_feeToken != address(0), "Invalid fee token");
        require(_destinationAddress != address(0), "Invalid destination address");
        
        vaultToken = IERC20(_vaultToken);
        feeToken = IERC20(_feeToken);
        destinationAddress = _destinationAddress;
    }
    
    function createVault() external nonReentrant {
        uint256 vaultId = userVaultCount[msg.sender];
        
        require(vaultToken.transferFrom(msg.sender, address(this), REQUIRED_DEPOSIT), "Transfer failed");
        
        vaults[msg.sender][vaultId] = Vault({
            balance: REQUIRED_DEPOSIT,
            depositBlock: block.number,
            lastDeductionBlock: block.number
        });
        
        userVaultCount[msg.sender]++;
        
        emit VaultCreated(msg.sender, vaultId, REQUIRED_DEPOSIT);
    }
    
    function calculateDeductions(address user, uint256 vaultId) public view returns (uint256) {
        Vault storage vault = vaults[user][vaultId];
        
        if (vault.balance < MINIMUM_BALANCE) {
            return 0;
        }
        
        uint256 blocksPassed = block.number - vault.lastDeductionBlock;
        uint256 totalDeduction = blocksPassed * DEDUCTION_RATE;
        
        return totalDeduction > vault.balance ? vault.balance : totalDeduction;
    }
    
    function isVaultEligible(address user, uint256 vaultId) public view returns (bool) {
        Vault storage vault = vaults[user][vaultId];
        uint256 deductions = calculateDeductions(user, vaultId);
        uint256 effectiveBalance = vault.balance > deductions ? vault.balance - deductions : 0;
        
        return effectiveBalance >= ELIGIBILITY_THRESHOLD;
    }
    
    function getCurrentWindowId() public view returns (uint256) {
        return block.number / WINDOW_SIZE;
    }
    
    function depositFees(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        uint256 windowId = getCurrentWindowId();
        
        require(feeToken.transferFrom(msg.sender, address(this), amount), "Fee transfer failed");
        
        feeWindows[windowId].totalFees += amount;
        
        emit FeeDeposited(windowId, amount);
    }
    
    function claimFees(uint256 windowId, uint256 vaultId) external nonReentrant {
        require(block.number >= (windowId + 1) * WINDOW_SIZE, "Window not finished");
        require(block.number <= (windowId + CLAIM_DEADLINE_MULTIPLIER) * WINDOW_SIZE, "Claim deadline passed");
        
        FeeWindow storage window = feeWindows[windowId];
        require(!window.hasClaimed[msg.sender], "Already claimed");
        require(isVaultEligible(msg.sender, vaultId), "Vault not eligible");
        
        uint256 feeShare = window.totalFees / window.totalEligibleVaults;
        window.hasClaimed[msg.sender] = true;
        
        require(feeToken.transfer(msg.sender, feeShare), "Fee transfer failed");
        
        emit FeesClaimed(msg.sender, windowId, feeShare);
    }
    
    function withdrawVaultTokens(uint256 vaultId) external nonReentrant {
        Vault storage vault = vaults[msg.sender][vaultId];
        require(block.number >= vault.depositBlock + WINDOW_SIZE, "Lock period not ended");
        
        uint256 deductions = calculateDeductions(msg.sender, vaultId);
        uint256 withdrawAmount = vault.balance > deductions ? vault.balance - deductions : 0;
        
        vault.balance = 0;
        vault.lastDeductionBlock = block.number;
        
        require(vaultToken.transfer(msg.sender, withdrawAmount), "Transfer failed");
        
        emit TokensWithdrawn(msg.sender, vaultId, withdrawAmount);
    }
    
    function crank() external nonReentrant {
        uint256 totalDeductions = 0;
        
        for (address user = address(1); user != address(0); user = address(uint160(user) + 1)) {
            uint256 vaultCount = userVaultCount[user];
            
            for (uint256 vaultId = 0; vaultId < vaultCount; vaultId++) {
                uint256 deduction = calculateDeductions(user, vaultId);
                if (deduction > 0) {
                    Vault storage vault = vaults[user][vaultId];
                    vault.balance -= deduction;
                    vault.lastDeductionBlock = block.number;
                    totalDeductions += deduction;
                }
            }
        }
        
        if (totalDeductions > 0) {
            require(vaultToken.transfer(destinationAddress, totalDeductions), "Deduction transfer failed");
            emit DeductionsCollected(totalDeductions);
        }
    }
    
    function emergencyWithdraw() external onlyOwner {
        uint256 vaultTokenBalance = vaultToken.balanceOf(address(this));
        uint256 feeTokenBalance = feeToken.balanceOf(address(this));
        
        if (vaultTokenBalance > 0) {
            require(vaultToken.transfer(owner(), vaultTokenBalance), "Vault token transfer failed");
        }
        
        if (feeTokenBalance > 0) {
            require(feeToken.transfer(owner(), feeTokenBalance), "Fee token transfer failed");
        }
    }
}
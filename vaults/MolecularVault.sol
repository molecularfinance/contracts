// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../common/TransferTokenHelper.sol";
import "../interfaces/IVaultStrategy.sol";
import "../interfaces/IMolecularVault.sol";

/**
* @notice Molecular assets vault
**/
contract MolecularVault is IMolecularVault, Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // @dev Amount of underlying tokens provided by the user.
    struct VaultUserInfo {
        uint256 amount;
    }

    // Vault strategy
    IVaultStrategy public strategy;

    // Vault asset token
    address public vaultAssets;

    // Total assets in the vault
    uint256 public totalAssets;

    // MainChef address
    address public mainChef;

    // Native address
    address public nativeAddress;

    // User map
    mapping(address => VaultUserInfo) public userInfoMap;

    // User list
    EnumerableSet.AddressSet private userList;

    /// @notice Emitted when user deposit assets
    /// @param user Address that deposited
    /// @param amount Deposit amount from user
    event DepositAssetsToVault(address indexed user, uint256 amount);

    /// @notice Emitted when user withdraw assets
    /// @param user Address that withdraw
    /// @param amount Withdrawal amount by user
    event WithdrawAssetsFromVault(address indexed user, uint256 amount);

    /// @notice Emitted when set the strategy
    event SetVaultStrategy(address indexed strategyAddr);

    /// @notice Emitted when set the mainChef
    event SetMainChef(address indexed mainChef);

    /// @notice Emitted when set the assets address
    event SetAssets(address indexed _assetsAddr);

    /// @notice Initialize the vault
    /// @param _vaultAssets The vault asset
    /// @param _nativeAddress The Native token address
    /// @param _mainChef The mainChef address
    function initialize(
        address _vaultAssets,
        address _nativeAddress,
        address _mainChef
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        vaultAssets = _vaultAssets;
        nativeAddress = _nativeAddress;
        mainChef = _mainChef;
    }

    /// @notice Set vault strategy
    /// @param _strategy Strategy address
    function setVaultStrategy(IVaultStrategy _strategy) external onlyOwner {
        strategy = _strategy;

        if (address(_strategy) != address(0)) {
            if (address(vaultAssets) != nativeAddress) {
                IERC20(vaultAssets).approve(address(_strategy), 0);
                IERC20(vaultAssets).approve(address(_strategy), type(uint256).max);
                transferERC20ToStrategy();
            } else {
                transferNativeToStrategy();
            }
        }

        emit SetVaultStrategy(address(_strategy));
    }

    /// @notice Set the mainChef
    /// @param _mainChef The mainChef address
    function setMainChef(address _mainChef) external onlyOwner {
        mainChef = _mainChef;

        emit SetMainChef(address(_mainChef));
    }

    /// @notice Set the assets of the vault
    /// @param _assets The assets of the vault
    function setAssets(address _assets) external onlyOwner {
        vaultAssets = _assets;

        emit SetAssets(_assets);
    }

    /// @notice Return vault pool balance only (strategy balance not included)
    function vaultBalance() external view returns (uint256) {
        return IERC20(vaultAssets).balanceOf(address(this));
    }

    /// @notice Return vault balance, included the strategy balance if has
    function balance() public view returns (uint256) {
        if (address(vaultAssets) == nativeAddress) {
            if (address(strategy) != address(0)) {
                return address(this).balance + IVaultStrategy(strategy).balanceOf();
            } else {
                return address(this).balance;
            }
        } else {
            if (address(strategy) != address(0)) {
                return IERC20(vaultAssets).balanceOf(address(this)) + IVaultStrategy(strategy).balanceOf();
            } else {
                return IERC20(vaultAssets).balanceOf(address(this));
            }
        }
    }

    /// @notice Return users list that interact with the vault
    function getVaultUserList() public view returns (address[] memory) {
        address[] memory _userList = userList.values();
        return _userList;
    }

    /// @notice Deposit assets to the vault
    /// @param _userAddr User address
    /// @param _amount Deposit amount
    function depositAssetsToVault(address _userAddr, uint256 _amount) public payable nonReentrant returns (uint256){
        require(msg.sender == mainChef, "!mainChef");
        require(_userAddr != address(0), "user address cannot be zero address");

        uint256 _depositAmount;
        if (vaultAssets == nativeAddress) {
            _depositAmount = _depositETH(_userAddr, msg.value);
        } else {
            _depositAmount = _deposit(_userAddr, mainChef, _amount);
        }

        userList.add(_userAddr);
        emit DepositAssetsToVault(_userAddr, _depositAmount);

        return _depositAmount;
    }

    /// @dev Process Native deposit
    function _depositETH(address _userAddr, uint256 _amount) private returns (uint256){
        VaultUserInfo storage _userInfo = userInfoMap[_userAddr];

        _userInfo.amount = _userInfo.amount + _amount;
        totalAssets = totalAssets + _amount;

        if (address(strategy) != address(0)) {
            IVaultStrategy(strategy).depositNative{value: _amount}(address(this));
        }

        return _amount;
    }

    /// @dev Deposit ERC20 assets
    function _deposit(address _userAddr, address _mainChef, uint256 _amount) private returns (uint256){
        VaultUserInfo storage _userInfo = userInfoMap[_userAddr];

        uint256 _poolBalance = balance();
        TransferTokenHelper.safeTokenTransferFrom(vaultAssets, _mainChef, address(this), _amount);

        uint256 _afterPoolBalance = balance();
        uint256 _depositAmount = _afterPoolBalance - _poolBalance;

        _userInfo.amount = _userInfo.amount + _depositAmount;
        totalAssets = totalAssets + _depositAmount;

        // deposit to strategy if has
        if (address(strategy) != address(0)) {
            IVaultStrategy(strategy).deposit(address(this), _depositAmount);
        }

        return _depositAmount;
    }

    /// @notice Withdraw assets from the vault
    /// @param _userAddr User Address
    /// @param _amount Withdrawal Amount
    function withdrawAssetsFromVault(address _userAddr, uint256 _amount) public nonReentrant returns (uint256){
        require(msg.sender == mainChef, "!mainChef");
        require(_userAddr != address(0), "User address cannot be zero address");

        VaultUserInfo storage _userInfo = userInfoMap[_userAddr];
        require(_userInfo.amount >= _amount, "Insufficient balance");

        _userInfo.amount = _userInfo.amount - _amount;
        totalAssets = totalAssets - _amount;

        if (address(vaultAssets) == nativeAddress) {
            // withdraw from strategy if has
            if (address(strategy) != address(0)) {
                IVaultStrategy(strategy).withdrawNative(_userAddr, _amount);
            } else {
                TransferTokenHelper.safeTransferNative(_userAddr, _amount);
            }

            emit WithdrawAssetsFromVault(_userAddr, _amount);
            return _amount;
        } else {
            // withdraw from strategy if has
            if (address(strategy) != address(0)) {
                IVaultStrategy(strategy).withdraw(_userAddr, _amount);
            } else {
                TransferTokenHelper.safeTokenTransfer(vaultAssets, _userAddr, _amount);
            }

            emit WithdrawAssetsFromVault(_userAddr, _amount);
            return _amount;
        }
    }

    // @dev Transfer Native to strategy
    function transferNativeToStrategy() internal {
        if (address(this).balance > 0) {
            TransferTokenHelper.safeTransferNative(address(strategy), address(this).balance);
        }
    }

    /// @dev Transfer ERC20 to strategy
    function transferERC20ToStrategy() internal {
        uint256 tokenBal = IERC20(vaultAssets).balanceOf(address(this));
        if (tokenBal > 0) {
            IERC20(vaultAssets).safeTransfer(address(strategy), tokenBal);
        }
    }

    receive() external payable {}
}
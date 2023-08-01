pragma solidity ^0.5.16;

import "../Controller/ControllerG1.sol";

contract ControllerScenarioG1 is ControllerG1 {
    uint public blockNumber;
    address public ucoreAddress;
    address public uaiAddress;
    /// @notice Supply caps enforced by mintAllowed for each vToken address. Defaults to zero which corresponds to minting notAllowed
    mapping(address => uint) public supplyCaps;

    constructor() public ControllerG1() {}

    function setUCOREAddress(address ucoreAddress_) public {
        ucoreAddress = ucoreAddress_;
    }

    function getUCOREAddress() public view returns (address) {
        return ucoreAddress;
    }

    function setUAIAddress(address uaiAddress_) public {
        uaiAddress = uaiAddress_;
    }

    function getUAIAddress() public view returns (address) {
        return uaiAddress;
    }

    function membershipLength(VToken vToken) public view returns (uint) {
        return accountAssets[address(vToken)].length;
    }

    function fastForward(uint blocks) public returns (uint) {
        blockNumber += blocks;

        return blockNumber;
    }

    function setBlockNumber(uint number) public {
        blockNumber = number;
    }

    function getBlockNumber() public view returns (uint) {
        return blockNumber;
    }

    function getUcoreMarkets() public view returns (address[] memory) {
        uint m = allMarkets.length;
        uint n = 0;
        for (uint i = 0; i < m; i++) {
            if (markets[address(allMarkets[i])].isUcore) {
                n++;
            }
        }

        address[] memory ucoreMarkets = new address[](n);
        uint k = 0;
        for (uint i = 0; i < m; i++) {
            if (markets[address(allMarkets[i])].isUcore) {
                ucoreMarkets[k++] = address(allMarkets[i]);
            }
        }
        return ucoreMarkets;
    }

    function unlist(VToken vToken) public {
        markets[address(vToken)].isListed = false;
    }

    /**
     * @notice Set the given supply caps for the given vToken markets. Supply that brings total Supply to or above supply cap will revert.
     * @dev Admin function to set the supply caps. A supply cap of 0 corresponds to Minting NotAllowed.
     * @param vTokens The addresses of the markets (tokens) to change the supply caps for
     * @param newSupplyCaps The new supply cap values in underlying to be set. A value of 0 corresponds to Minting NotAllowed.
     */
    function _setMarketSupplyCaps(VToken[] calldata vTokens, uint[] calldata newSupplyCaps) external {
        require(msg.sender == admin, "only admin can set supply caps");

        uint numMarkets = vTokens.length;
        uint numSupplyCaps = newSupplyCaps.length;

        require(numMarkets != 0 && numMarkets == numSupplyCaps, "invalid input");

        for (uint i = 0; i < numMarkets; i++) {
            supplyCaps[address(vTokens[i])] = newSupplyCaps[i];
        }
    }
}

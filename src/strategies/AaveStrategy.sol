// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IAToken} from "@aave/contracts/interfaces/IAToken.sol";
import {DataTypes} from "@aave/contracts/protocol/libraries/types/DataTypes.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/**
 * @title AaveStrategy
 * @author cristianrisueo
 * @notice Estrategia que deposita WETH en Aave v3 para generar yield
 * @dev Implementa IStrategy para integracion con StrategyManager
 */
contract AaveStrategy is IStrategy {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    //* Errores

    /**
     * @notice Error cuando el depósito en Aave falla
     */
    error AaveStrategy__DepositFailed();

    /**
     * @notice Error cuando el retiro de Aave falla
     */
    error AaveStrategy__WithdrawFailed();

    /**
     * @notice Error cuando solo el manager puede llamar
     */
    error AaveStrategy__OnlyManager();

    //* Variables de estado

    /// @notice Direccion del StrategyManager autorizado
    address public immutable manager;

    /// @notice Instancia del Pool de Aave v3
    IPool private immutable aave_pool;

    /// @notice Token que representa los assets depositados en Aave (aWETH)
    IAToken private immutable a_weth;

    /// @notice Direccion del asset subyacente (WETH)
    address private immutable weth_address;

    //* Modificadores

    /**
     * @notice Solo permite llamadas del StrategyManager
     */
    modifier onlyManager() {
        if (msg.sender != manager) revert AaveStrategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor de AaveStrategy
     * @dev Inicializa la strategy con Aave v3 y aprueba el pool
     * @param _manager Direccion del StrategyManager
     * @param _weth Direccion del token WETH
     * @param _aave_pool Direccion del Pool de Aave v3
     */
    constructor(address _manager, address _weth, address _aave_pool) {
        // Asigna las direcciones de StrategyManager y WETH. Inicializa pool de Aave
        manager = _manager;
        weth_address = _weth;
        aave_pool = IPool(_aave_pool);

        // Obtiene la direccion del aToken dinamicamente desde Aave
        address a_weth_address = aave_pool.getReserveData(_weth).aTokenAddress;
        a_weth = IAToken(a_weth_address);

        // Aprueba Aave Pool para mover todo WETH de esta strategy
        IERC20(_weth).forceApprove(_aave_pool, type(uint256).max);
    }

    //* Implementacion de IStrategy

    /**
     * @notice Deposita WETH en Aave v3
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Asume que el WETH ya fue transferido a esta strategy desde StrategyManager
     * @param assets Cantidad de WETH a depositar en Aave
     * @return shares En Aave es 1:1, devuelve la misma cantidad de aToken
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Realiza el depósito, devuelve el aWETH y emite evento. En caso de error revierte
        try aave_pool.supply(weth_address, assets, address(this), 0) {
            shares = assets;
            emit Deposited(msg.sender, assets, shares);
        } catch {
            revert AaveStrategy__DepositFailed();
        }
    }

    /**
     * @notice Retira WETH de Aave v3
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Transfiere el WETH retirado directamente al manager
     * @param assets Cantidad de WETH a retirar de Aave
     * @return actualWithdrawn WETH realmente retirado (incluye yield)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actualWithdrawn) {
        // Realiza withdraw de Aave (quema aWETH, recibe WETH + yield). Transfiere a StrategyManager
        // y emite evento, en caso de error revierte
        try aave_pool.withdraw(weth_address, assets, address(this)) returns (uint256 withdrawn) {
            actualWithdrawn = withdrawn;
            IERC20(weth_address).safeTransfer(msg.sender, actualWithdrawn);
            emit Withdrawn(msg.sender, actualWithdrawn, assets);
        } catch {
            revert AaveStrategy__WithdrawFailed();
        }
    }

    /**
     * @notice Devuelve el total de assets bajo gestion en Aave
     * @dev Los aTokens hacen rebase automatico, el balance ya incluye yield
     *      por lo que no hay que hacer cálculos extra
     * @return total Cantidad de WETH depositado + yield acumulado
     */
    function totalAssets() external view returns (uint256 total) {
        return a_weth.balanceOf(address(this));
    }

    /**
     * @notice Devuelve el APY actual de Aave para WETH
     * @dev Convierte de RAY (1e27, unidad interna de Aave) a basis points (1e4)
     *      RAY / 1e23 = basis points
     * @return apyBasisPoints APY en basis points (350 = 3.5%)
     */
    function apy() external view returns (uint256 apyBasisPoints) {
        // Obtiene los datos de las reservas de WETH en Aave
        DataTypes.ReserveData memory reserve_data = aave_pool.getReserveData(weth_address);
        uint256 liquidity_rate = reserve_data.currentLiquidityRate;

        // Devuelve el APY (liquidity rate) en basis points
        apyBasisPoints = liquidity_rate / 1e23;
    }

    /**
     * @notice Devuelve el nombre de la strategy
     * @return strategyName Nombre descriptivo de la strategy
     */
    function name() external pure returns (string memory strategyName) {
        return "Aave v3 WETH Strategy";
    }

    /**
     * @notice Devuelve la direccion del asset
     * @return assetAddress Direccion de WETH
     */
    function asset() external view returns (address assetAddress) {
        return weth_address;
    }

    //* Funciones de utilidad

    /**
     * @notice Devuelve la liquidez disponible en Aave para withdraws
     * @dev Util para verificar si hay suficiente liquidez antes de retirar
     * @return available Cantidad de WETH disponible en Aave
     */
    function availableLiquidity() external view returns (uint256 available) {
        return IERC20(weth_address).balanceOf(address(a_weth));
    }

    /**
     * @notice Devuelve el balance de aWETH de esta strategy
     * @return balance Cantidad de aWETH que posee la strategy
     */
    function aTokenBalance() external view returns (uint256 balance) {
        return a_weth.balanceOf(address(this));
    }
}

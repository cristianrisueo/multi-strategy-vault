// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/**
 * @title StrategyManager
 * @author cristianrisueo
 * @notice Cerebro del protocolo que decide donde invertir y ejecuta rebalancing
 * @dev Compara APYs, selecciona mejor strategy y solo rebalancea si es rentable
 */
contract StrategyManager is Ownable {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    //* Errores

    /**
     * @notice Error cuando no hay strategies disponibles
     */
    error StrategyManager__NoStrategiesAvailable();

    /**
     * @notice Error cuando se intenta agregar una strategy duplicada
     */
    error StrategyManager__StrategyAlreadyExists();

    /**
     * @notice Error cuando se intenta remover una strategy que no existe
     */
    error StrategyManager__StrategyNotFound();

    /**
     * @notice Error cuando el rebalance no es rentable
     */
    error StrategyManager__RebalanceNotProfitable();

    /**
     * @notice Error cuando se intenta operar con cantidad cero
     */
    error StrategyManager__ZeroAmount();

    /**
     * @notice Error cuando solo el vault puede llamar
     */
    error StrategyManager__OnlyVault();

    //* Eventos

    /**
     * @notice Emitido cuando se deposita en una strategy
     * @param strategy Direccion de la estrategia
     * @param assets Cantidad depositada
     */
    event Allocated(address indexed strategy, uint256 assets);

    /**
     * @notice Emitido cuando se ejecuta un rebalance
     * @param from_strategy Estrategia desde donde se retiran fondos
     * @param to_strategy Estrategia a donde se mueven fondos
     * @param assets Cantidad rebalanceada
     */
    event Rebalanced(address indexed from_strategy, address indexed to_strategy, uint256 assets);

    /**
     * @notice Emitido cuando se agrega una nueva estrategia
     * @param strategy Direccion de la estrategia agregada
     */
    event StrategyAdded(address indexed strategy);

    /**
     * @notice Emitido cuando se remueve una estrategia
     * @param strategy Direccion de la estrategia removida
     */
    event StrategyRemoved(address indexed strategy);

    //* Variables de estado

    /// @notice Direccion del vault autorizado para llamar allocate/withdraw
    address public immutable vault;

    /// @notice Array de strategies disponibles
    IStrategy[] public strategies;

    /// @notice Mapeo para verificar rapidamente si una estrategia existe
    mapping(address => bool) public is_strategy;

    /// @notice Direccion del asset gestionado (WETH)
    address public immutable asset;

    /// @notice Threshold minimo de diferencia de APY para considerar rebalance (2% en basis points)
    uint256 public rebalance_threshold = 200;

    /// @notice TVL minimo para ejecutar rebalance (evita rebalancear cantidades pequeñas)
    uint256 public min_tvl_for_rebalance = 10 ether;

    /// @notice Multiplicador de gas cost para margen de seguridad al rebalancear (base 100, 200 -> 2x)
    uint256 public gas_cost_multiplier = 200;

    //* Modificadores

    /**
     * @notice Solo permite llamadas del vault
     */
    modifier onlyVault() {
        if (msg.sender != vault) revert StrategyManager__OnlyVault();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor del StrategyManager
     * @dev Inicializa las direcciones del vault y asset
     * @param _vault Direccion del StrategyVault
     * @param _asset Direccion del asset (WETH)
     */
    constructor(address _vault, address _asset) Ownable(msg.sender) {
        vault = _vault;
        asset = _asset;
    }

    //* Funciones principales: Depósito, Retiro y rebalance de assets

    /**
     * @notice Deposita assets en la strategy con mejor APY
     * @dev Solo puede ser llamado por el vault
     * @dev El vault debe transferir WETH a este manager antes de llamar
     * @param assets Cantidad de WETH a invertir
     */
    function allocate(uint256 assets) external onlyVault {
        // Comprueba que la cantidad a transferir no sea 0 y que existan estrategias disponibles
        if (assets == 0) revert StrategyManager__ZeroAmount();
        if (strategies.length == 0) revert StrategyManager__NoStrategiesAvailable();

        // Encuentra la estrategia con mejor APY
        IStrategy best_strategy = _getBestStrategy();

        // Transfiere WETH a la estrategia y ejecuta el depósito usando dicha estrategia
        IERC20(asset).safeTransfer(address(best_strategy), assets);
        best_strategy.deposit(assets);

        // Emite evento de assets asignados
        emit Allocated(address(best_strategy), assets);
    }

    /**
     * @notice Retira assets del manager hacia el vault
     * @dev Solo puede ser llamado por el vault
     * @dev Retira de las estrategias con fondos hasta cubrir la cantidad solicitada
     *      Al final el manager simplemente decide y redirige los assets, pero posee
     * @param assets Cantidad de WETH a retirar
     * @param receiver Direccion que recibira los assets (normalmente el vault)
     */
    function withdrawTo(uint256 assets, address receiver) external onlyVault {
        // Comprueba que la cantidad a retirar no sea 0
        if (assets == 0) revert StrategyManager__ZeroAmount();

        // Setea los assets que quedan pendientes de retirar de las estrategias
        uint256 remaining = assets;

        // Itera sobre cada estrategia y retira de su balance hasta cubrir los assets necesarios
        for (uint256 i = 0; i < strategies.length && remaining > 0; i++) {
            // Selecciona el balance de la primera estrategia
            IStrategy strategy = strategies[i];
            uint256 strategy_balance = strategy.totalAssets();

            // Si esa estrategia no tiene assets depositados salta la iteración
            if (strategy_balance == 0) continue;

            // Retira lo minimo entre: lo que queda pendiente de retirar y el balance de la estrategia
            uint256 to_withdraw = remaining > strategy_balance ? strategy_balance : remaining;

            // Realiza el retiro de la estrategia y resta la cantidad de los assets pendientes
            strategy.withdraw(to_withdraw);
            remaining -= to_withdraw;
        }

        // Una vez finalizados las extracciones de las estrategias transfiere WETH al receiver (vault)
        IERC20(asset).safeTransfer(receiver, assets);
    }

    /**
     * @notice Ejecuta rebalance si es rentable
     * @dev Mueve fondos de la estrategia actual a la mejor estrategia disponible
     * @dev Solo ejecuta si el profit esperado supera el gas cost
     */
    function rebalance() external {
        // Llama a la función shouldRebalance para comprobar si debe rebalancear los assets
        (bool should_rebalance, IStrategy from_strategy, IStrategy to_strategy, uint256 amount) = shouldRebalance();

        // En caso negativo revierte
        if (!should_rebalance) revert StrategyManager__RebalanceNotProfitable();

        // En caso afirmativo extrae los assets de la estrategia actual, transfiere a la nueva y deposita
        from_strategy.withdraw(amount);

        IERC20(asset).safeTransfer(address(to_strategy), amount);
        to_strategy.deposit(amount);

        // Por último emite evento de fondos rebalanceados
        emit Rebalanced(address(from_strategy), address(to_strategy), amount);
    }

    /**
     * @notice Calcula si un rebalance es rentable
     * @dev Compara profit esperado vs gas cost estimado
     * @return should_rebalance True si el rebalance es rentable
     * @return from_strategy Estrategia desde donde mover fondos
     * @return to_strategy Estrategia hacia donde mover fondos
     * @return amount Cantidad a rebalancear
     */
    function shouldRebalance()
        public
        view
        returns (bool should_rebalance, IStrategy from_strategy, IStrategy to_strategy, uint256 amount)
    {
        // Comprueba que al menos existan dos estrategias, de lo contrario no hay nada que mover
        if (strategies.length < 2) return (false, IStrategy(address(0)), IStrategy(address(0)), 0);

        uint256 max_tvl = 0;

        // Encuentra la estrategia actual (porque será la que tenga mayor TVL)
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 strategy_tvl = strategies[i].totalAssets();

            if (strategy_tvl > max_tvl) {
                max_tvl = strategy_tvl;
                from_strategy = strategies[i];
            }
        }

        // Si el TVL es menor que el minimo que hemos setado, no se rebalancean los fondos
        if (max_tvl < min_tvl_for_rebalance) {
            return (false, IStrategy(address(0)), IStrategy(address(0)), 0);
        }

        // Encuentra la mejor estrategia actual (la que mayor APY tenga)
        to_strategy = _getBestStrategy();

        // Si la mejor es la misma que la actual, no se rebalancean los fondos
        if (address(from_strategy) == address(to_strategy)) {
            return (false, IStrategy(address(0)), IStrategy(address(0)), 0);
        }

        // Calcula las diferencias de APY entre la estrategia actual y la mejor
        uint256 current_apy = from_strategy.apy();
        uint256 best_apy = to_strategy.apy();

        // Si diferencia es menor que threshold establecido (2%), no se rebalancean los fondos
        if (best_apy <= current_apy + rebalance_threshold) {
            return (false, IStrategy(address(0)), IStrategy(address(0)), 0);
        }

        // Calcula el profit esperado en una semana
        uint256 apy_diff = best_apy - current_apy;

        uint256 annual_profit = (max_tvl * apy_diff) / 10000; // apy en basis points
        uint256 weekly_profit = (annual_profit * 7) / 365;

        // Estima gas cost en un escenario conservador:
        // withdraw: ~150k gas, deposit: ~150k gas -> 300k total
        uint256 estimated_gas = 300000 * tx.gasprice;

        // Rebalancea si profit semanal > (gas_cost * multiplier / 100)
        should_rebalance = weekly_profit > (estimated_gas * gas_cost_multiplier / 100);

        // Setea la cantidad rebalanceada, la que retornamos (putos named returns, tenemos más líneas)
        amount = max_tvl;
    }

    //* Funciones administrativas: Añadir y quitar estrategias; y setear los valores del manager

    /**
     * @notice Agrega una nueva estrategia al manager
     * @dev Solo el owner puede agregar estrategias
     * @param strategy Address de la estrategia a agregar
     */
    function addStrategy(address strategy) external onlyOwner {
        // Comprueba si la estrategia ya ha sido agregada
        if (is_strategy[strategy]) revert StrategyManager__StrategyAlreadyExists();

        // Si no ha sido agregada la añade al array y al mapping de verificación rápida
        strategies.push(IStrategy(strategy));
        is_strategy[strategy] = true;

        // Emite evento de estrategia agregada
        emit StrategyAdded(strategy);
    }

    /**
     * @notice Remueve una estrategia del manager
     * @dev Solo el owner puede remover strategies
     * @dev La estrategia debe tener balance cero antes de ser removida
     * @param strategy Direccion de la estrategia a remover
     */
    function removeStrategy(address strategy) external onlyOwner {
        // Comprueba si la estrategia no ha sido agregada
        if (!is_strategy[strategy]) revert StrategyManager__StrategyNotFound();

        // Encuentra el indice de la strategy en el array
        uint256 index;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (address(strategies[i]) == strategy) {
                index = i;
                break;
            }
        }

        // Elimina la estrategia del array el mapping de verificación rápida
        // Usa la técnica swap&pop de arrays que es mas eficiente en cuanto a gas
        strategies[index] = strategies[strategies.length - 1];
        strategies.pop();
        is_strategy[strategy] = false;

        // Emite evento de estrategia removida
        emit StrategyRemoved(strategy);
    }

    /**
     * @notice Actualiza el threshold minimo para rebalancing
     * @param new_threshold Nuevo threshold en basis points
     */
    function setRebalanceThreshold(uint256 new_threshold) external onlyOwner {
        rebalance_threshold = new_threshold;
    }

    /**
     * @notice Actualiza el TVL minimo para rebalancing
     * @param new_min_tvl Nuevo TVL minimo en wei
     */
    function setMinTVLForRebalance(uint256 new_min_tvl) external onlyOwner {
        min_tvl_for_rebalance = new_min_tvl;
    }

    /**
     * @notice Actualiza el multiplicador de gas cost para rebalancing
     * @dev Base 100: 200 = 2x, 300 = 3x, 150 = 1.5x
     * @param new_multiplier Nuevo multiplicador
     */
    function setGasCostMultiplier(uint256 new_multiplier) external onlyOwner {
        gas_cost_multiplier = new_multiplier;
    }

    //* Funciones internas

    /**
     * @notice Encuentra la estrategia con mejor APY
     * @dev Helper interno usado por allocate y rebalance
     * @return best_strategy Estrategia con el APY mas alto
     */
    function _getBestStrategy() internal view returns (IStrategy best_strategy) {
        uint256 best_apy = 0;

        // La funcionalidad es sencilla. Recorre y compara, el mayor se setea y devuelve
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 current_apy = strategies[i].apy();

            if (current_apy > best_apy) {
                best_apy = current_apy;
                best_strategy = strategies[i];
            }
        }
    }

    //* Funciones de consulta

    /**
     * @notice Devuelve el total de assets bajo gestion en todas las estrategias
     * @dev Cada estrategia realmente tiene un xToken del protocolo dónde se deposita el
     *      asset. Lo que obtenemos aquí es la suma total de todos los xTokens convertidos
     *      al underlying asset usado en el protocolo (osea, el WETH + yield generado)
     * @return total Suma de assets en todas las estrategias
     */
    function totalAssets() external view returns (uint256 total) {
        for (uint256 i = 0; i < strategies.length; i++) {
            total += strategies[i].totalAssets();
        }
    }

    /**
     * @notice Devuelve el numero de strategies disponibles
     * @return count Cantidad de strategies
     */
    function strategiesCount() external view returns (uint256 count) {
        return strategies.length;
    }

    /**
     * @notice Devuelve informacion de todas las strategies
     * @return names Nombres de las strategies
     * @return apys APYs de cada strategy
     * @return tvls TVL de cada strategy
     */
    function getAllStrategiesInfo()
        external
        view
        returns (string[] memory names, uint256[] memory apys, uint256[] memory tvls)
    {
        // Tamaño del array de estrategias
        uint256 length = strategies.length;

        // Nuevos arrays con el tamaño seteado
        names = new string[](length);
        apys = new uint256[](length);
        tvls = new uint256[](length);

        // Recorre el array de estrategias y setea valores en los nuevos arrays
        for (uint256 i = 0; i < length; i++) {
            names[i] = strategies[i].name();
            apys[i] = strategies[i].apy();
            tvls[i] = strategies[i].totalAssets();
        }
    }
}

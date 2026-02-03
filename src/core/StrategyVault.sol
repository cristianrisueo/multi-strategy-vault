// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {StrategyManager} from "../core/StrategyManager.sol";

/**
 * @title StrategyVault
 * @author cristianrisueo
 * @notice Vault ERC4626 que delega inversion a StrategyManager con idle buffer
 * @dev Acumula WETH hasta alcanzar threshold antes de depositar en manager y subsecuentes estrategias
 *      Hacemos esto usando un idle buffer para WETH, y nos permite ahorrar gas al acumular depósitos
 */
contract StrategyVault is ERC4626, Ownable, Pausable {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    //* Errores

    /**
     * @notice Error cuando se intenta depositar cantidad cero
     */
    error StrategyVault__ZeroAmount();

    /**
     * @notice Error cuando el TVL maximo es excedido
     */
    error StrategyVault__MaxTVLExceeded();

    /**
     * @notice Error cuando el idle WETH es menor que el threshold para depositar
     */
    error StrategyVault__IdleBelowThreshold();

    //* Eventos

    /**
     * @notice Emitido cuando un usuario deposita assets en el vault
     * @param user Direccion del usuario que realiza el deposito
     * @param assets Cantidad de assets depositados
     * @param shares Cantidad de shares mintadas al usuario
     */
    event Deposited(address indexed user, uint256 assets, uint256 shares);

    /**
     * @notice Emitido cuando un usuario retira assets del vault
     * @param user Direccion del usuario que realiza el retiro
     * @param assets Cantidad de assets retirados
     * @param shares Cantidad de shares quemadas del usuario
     */
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);

    /**
     * @notice Emitido cuando se deposita WETH en estado idle al manager
     * @param amount Cantidad de WETH enviada al manager
     */
    event IdleAllocated(uint256 amount);

    /**
     * @notice Emitido cuando se actualiza el idle threshold
     * @param old_threshold Threshold anterior
     * @param new_threshold Nuevo threshold
     */
    event IdleThresholdUpdated(uint256 old_threshold, uint256 new_threshold);

    /**
     * @notice Emitido cuando se actualiza el max TVL
     * @param old_max TVL maximo anterior
     * @param new_max Nuevo TVL maximo
     */
    event MaxTVLUpdated(uint256 old_max, uint256 new_max);

    //* Variables de estado

    /// @notice Instancia del StrategyManager que gestiona las estrategias
    StrategyManager public immutable strategy_manager;

    /// @notice Cantidad de WETH idle (pendiente de enviar al manager) acumulado en el vault
    uint256 public idle_weth;

    /// @notice Threshold minimo de idle WETH para ejecutar el depósito automaticamente
    uint256 public idle_threshold;

    /// @notice TVL maximo permitido en el vault (circuit breaker, mejor no acumular mucho)
    uint256 public max_tvl;

    //* Constructor

    /**
     * @notice Constructor del StrategyVault
     * @dev Inicializa el vault ERC4626, inicaliza el StrategyManager y configura los
     *      parámetros del vault
     * @param _asset Direccion del token subyacente (WETH)
     * @param _strategy_manager Direccion del StrategyManager
     * @param _idle_threshold Threshold inicial para auto-allocate (ej: 10 ether)
     */
    constructor(address _asset, address _strategy_manager, uint256 _idle_threshold)
        ERC4626(IERC20(_asset))
        ERC20("Multi-Strategy Vault WETH", "msvWETH")
        Ownable(msg.sender)
    {
        strategy_manager = StrategyManager(_strategy_manager);
        idle_threshold = _idle_threshold;
        max_tvl = 1000 ether;

        // Aprueba a StrategyManager para mover todo el WETH del vault
        IERC20(_asset).forceApprove(_strategy_manager, type(uint256).max);
    }

    //* Funciones principales: deposit, mint, withdraw y redeem

    /**
     * @notice Deposita WETH en el vault y mintea shares al usuario en base a esos assets
     * @dev Override de ERC4626.deposit()
     * @dev WETH se acumula como idle hasta alcanzar threshold, luego se envía al manager
     * @param assets Cantidad de WETH a depositar
     * @param receiver Direccion que recibira las shares
     * @return shares Cantidad de shares mintadas al usuario
     */
    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256 shares) {
        // Comprueba que no se deposite 0 WETH
        if (assets == 0) revert StrategyVault__ZeroAmount();

        // Comprueba que no se exceda el max TVL del vault
        if (totalAssets() + assets > max_tvl) {
            revert StrategyVault__MaxTVLExceeded();
        }

        // Calcula shares a mintear (antes de modificar balances)
        shares = previewDeposit(assets);

        // Transfiere WETH del usuario al vault
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        // Acumula en idle (no deposita todavia)
        idle_weth += assets;

        // Mintea shares al usuario
        _mint(receiver, shares);

        // Si idle supera threshold, deposita automaticamente
        if (idle_weth >= idle_threshold) {
            _allocateIdle();
        }

        // Emite evento de depósito y devuelve cantidad de shares minteadas
        emit Deposited(receiver, assets, shares);
    }

    /**
     * @notice Mintea shares exactas al usuario depositando los assets necesarios primero
     * @dev Override de ERC4626.mint()
     * @param shares Cantidad de shares a mintear
     * @param receiver Direccion que recibira las shares
     * @return assets Cantidad de WETH depositados
     */
    function mint(uint256 shares, address receiver) public override whenNotPaused returns (uint256 assets) {
        // Comprueba que no se minteen 0 shares
        if (shares == 0) revert StrategyVault__ZeroAmount();

        // Calcula assets necesarios para mintear la cantidad de shares
        assets = previewMint(shares);

        // Comprueba que no se exceda el max TVL
        if (totalAssets() + assets > max_tvl) {
            revert StrategyVault__MaxTVLExceeded();
        }

        // Transfiere el WETH necesario del usuario al vault
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        // Acumula los assets transferidos en el buffer idle
        idle_weth += assets;

        // Mintea shares al usuario
        _mint(receiver, shares);

        // Si idle supera threshold, deposita automaticamente
        if (idle_weth >= idle_threshold) {
            _allocateIdle();
        }

        // Emite evento de depósito y devuelve cantidad de assets que se han necesitado
        emit Deposited(receiver, assets, shares);
    }

    /**
     * @notice Retira WETH del vault quemando shares
     * @dev Override de ERC4626.withdraw()
     * @dev Primero retira de idle, luego del manager si es necesario. Así ahorramos gas
     * @param assets Cantidad de WETH a retirar
     * @param receiver Direccion que recibira el WETH
     * @param owner Direccion owner de las shares a quemar
     * @return shares Cantidad de shares quemadas
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256 shares)
    {
        // Comprueba que no se retiren 0 assets
        if (assets == 0) revert StrategyVault__ZeroAmount();

        // Calcula las shares a quemar a partir de los assets que quiere retirar el usuario
        shares = previewWithdraw(assets);

        // Comprueba allowance del owner si el owner no es el msg.sender
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Quema las respectivas shares antes de retirar (previene reentrancy)
        _burn(owner, shares);

        // Retira los assets: primero de idle, luego del manager
        _withdrawAssets(assets, receiver);

        // Emite evento de assets retirados y devuelve la cantidad
        emit Withdrawn(receiver, assets, shares);
    }

    /**
     * @notice Quema shares y retira WETH proporcional
     * @dev Override de ERC4626.redeem()
     * @param shares Cantidad de shares a quemar
     * @param receiver Direccion que recibira el WETH
     * @param owner Direccion duena de las shares
     * @return assets Cantidad de WETH retirada
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256 assets)
    {
        // Comprueba que no se quemen 0 shares
        if (shares == 0) revert StrategyVault__ZeroAmount();

        // Calcula los assets a retirar a partir de las shares que quiere quemar el usuario
        assets = previewRedeem(shares);

        // Comprueba allowance del owner si el owner no es el msg.sender
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Quema las respectivas shares antes de retirar (previene reentrancy)
        _burn(owner, shares);

        // Retira los assets: primero de idle, luego del manager
        _withdrawAssets(assets, receiver);

        // Emite evento de assets retirados y devuelve la cantidad
        emit Withdrawn(receiver, assets, shares);
    }

    //* Funciones internas: allocation y withdrawal

    /**
     * @notice Transfiere idle WETH del vault al StrategyManager
     * @dev Funcion interna que centraliza logica de allocate
     */
    function _allocateIdle() internal {
        // Asigna la cantidad a partir del idle buffer
        uint256 amount = idle_weth;

        // Resetea idle buffer a 0
        idle_weth = 0;

        // Transfiere el WETH del idle buffer al manager y ejecuta la función allocate de este
        IERC20(asset()).safeTransfer(address(strategy_manager), amount);
        strategy_manager.allocate(amount);

        // Emite evento de idle WETH transferido al manager
        emit IdleAllocated(amount);
    }

    /**
     * @notice Retira assets del vault (primero buffler idle, luego manager)
     * @dev Helper interno usado por withdraw y redeem
     * @param assets Cantidad de WETH a retirar
     * @param receiver Direccion que recibe los assets
     */
    function _withdrawAssets(uint256 assets, address receiver) internal {
        // Setea la cantidad que se extraerá del idle buffer
        uint256 from_idle = 0;

        // Si el buffer idle tiene WETH calcula cuanto retirar del buffer
        // Dependiendo de la cantidad retira todo el buffler o solo lo que quiere el usuario
        if (idle_weth > 0) {
            from_idle = assets > idle_weth ? idle_weth : assets;
            idle_weth -= from_idle;
        }

        // Calcula cuanto retirar del manager (con un poco de suerte nada)
        // Si hay que retirar algo llama al método del manager para transferir los assets necesarios
        uint256 from_manager = assets - from_idle;
        if (from_manager > 0) {
            strategy_manager.withdrawTo(from_manager, address(this));
        }

        // Transfiere WETH al receiver
        IERC20(asset()).safeTransfer(receiver, assets);
    }

    //* Funciones para allocation manual

    /**
     * @notice Transfiere WETH del idle buffer al manager manualmente
     * @dev Puede ser llamada por cualquiera (keeper bots, frontends, etc)
     * @dev Solo ejecuta si idle >= threshold
     */
    function allocateIdle() external {
        if (idle_weth < idle_threshold) revert StrategyVault__IdleBelowThreshold();
        _allocateIdle();
    }

    /**
     * @notice Fuerza allocate del idle buffer sin comprobar el threshold
     * @dev Solo puede ser llamado por el owner (algún caso de uso tendrá)
     *      solo comprueba que el buffer no sea cero
     */
    function forceAllocateIdle() external onlyOwner {
        if (idle_weth == 0) revert StrategyVault__ZeroAmount();
        _allocateIdle();
    }

    //* Overrides de ERC4626 para calcular TVL y limites

    /**
     * @notice Calcula total de assets bajo gestion del vault
     * @dev Incluye WETH idle + assets en estrategias
     * @return total Total de WETH en el vault
     */
    function totalAssets() public view override returns (uint256 total) {
        return idle_weth + strategy_manager.totalAssets();
    }

    /**
     * @notice Maximo que se puede depositar (circuit breaker)
     * @dev parámetro tipo address ignorado (requerido por ERC4626)
     * @return max_deposit Cantidad maxima de WETH que se puede depositar
     */
    function maxDeposit(address) public view override returns (uint256 max_deposit) {
        // Si el vault esta pausado, directamente no se puede depositar
        if (paused()) return 0;

        // Recoge el TVL actual y si es mayor o igual al máximo, no se puede depositar más
        uint256 current_tvl = totalAssets();
        if (current_tvl >= max_tvl) return 0;

        // Devuelve la diferencia entre max y actual, es decir, lo que aún se puede
        return max_tvl - current_tvl;
    }

    /**
     * @notice Maximo que un usuario puede retirar
     * @param owner Direccion del usuario que quiere retirar
     * @return max_withdraw Cantidad maxima de WETH que se puede retirar
     */
    function maxWithdraw(address owner) public view override returns (uint256 max_withdraw) {
        // Si el vault esta pausado, directamente no se puede depositar
        if (paused()) {
            max_withdraw = 0;
        }
        // Si no está pausado calcula los assets del usuario a partir de sus shares
        else {
            max_withdraw = convertToAssets(balanceOf(owner));
        }
    }

    //* Funciones administrativas: Pausar y despausar el vault, y setters

    /**
     * @notice Pausa deposits y withdraws
     * @dev Solo el owner puede llamarla
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Despausa deposits y withdraws
     * @dev Solo el owner puede llamarla
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Actualiza el threshold de idle WETH para auto-allocate
     * @dev Solo el owner puede llamarla
     * @param new_threshold Nuevo threshold en wei
     */
    function setIdleThreshold(uint256 new_threshold) external onlyOwner {
        emit IdleThresholdUpdated(idle_threshold, new_threshold);
        idle_threshold = new_threshold;
    }

    /**
     * @notice Actualiza el max TVL del vault
     * @dev Solo el owner puede llamarla
     * @param new_max_tvl Nuevo maximo TVL en wei
     */
    function setMaxTVL(uint256 new_max_tvl) external onlyOwner {
        emit MaxTVLUpdated(max_tvl, new_max_tvl);
        max_tvl = new_max_tvl;
    }

    //* Funciones de consulta: TVL (sin buffer), buffer pendiente y si se puede transferir el buffer

    /**
     * @notice Devuelve el TVL invertido en estrategias (sin idle)
     * @return invested TVL en estrategias via manager
     */
    function investedAssets() external view returns (uint256 invested) {
        return strategy_manager.totalAssets();
    }

    /**
     * @notice Devuelve cuanto idle WETH hay acumulado
     * @return idle Cantidad de WETH idle
     */
    function idleAssets() external view returns (uint256 idle) {
        return idle_weth;
    }

    /**
     * @notice Devuelve si el vault puede transferir el buffer al manager ahora
     * @return can_allocate True si idle >= threshold
     */
    function canAllocate() external view returns (bool can_allocate) {
        return idle_weth >= idle_threshold;
    }
}

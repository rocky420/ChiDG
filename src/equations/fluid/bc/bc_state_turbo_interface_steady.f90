module bc_state_turbo_interface_steady
#include <messenger.h>
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: ZERO, ONE, TWO, HALF, ME, CYLINDRICAL,    &
                                      XI_MIN, XI_MAX, ETA_MIN, ETA_MAX, ZETA_MIN, ZETA_MAX, PI
    use mod_fluid,              only: gam, Rgas, cp
    use mod_interpolation,      only: interpolate_linear, interpolate_linear_ad
    use mod_gridspace,          only: linspace
    use mod_dft,                only: idft_eval
    use mod_chimera,            only: find_gq_donor, find_gq_donor_parallel

    use type_point,             only: point_t
    use type_mesh,              only: mesh_t
    use type_bc_state,          only: bc_state_t
    use bc_giles_HB_base,       only: giles_HB_base_t
    use type_bc_patch,          only: bc_patch_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_properties,        only: properties_t
    use type_face_info,         only: face_info_t, face_info_constructor
    use type_element_info,      only: element_info_t
    use mod_chidg_mpi,          only: IRANK
    use mod_interpolate,        only: interpolate_face_autodiff
    use mpi_f08,                only: MPI_REAL8, MPI_AllReduce, mpi_comm, MPI_INTEGER, MPI_BCast, MPI_MIN, MPI_MAX
    use ieee_arithmetic,        only: ieee_is_nan
    use DNAD_D
    implicit none



    !>  Name: inlet - 3D Giles
    !!
    !!  Options:
    !!      : Average Pressure
    !!
    !!  Behavior:
    !!      
    !!  References:
    !!              
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2018
    !!
    !---------------------------------------------------------------------------------
    type, public, extends(giles_HB_base_t) :: turbo_interface_steady_t

    contains

        procedure   :: init                 ! Set-up bc state with options/name etc.
        procedure   :: compute_bc_state     ! boundary condition function implementation
        procedure   :: get_q_exterior

    end type turbo_interface_steady_t
    !*********************************************************************************




contains



    !>
    !!
    !!  @author Nathan A. average_pressure 
    !!  @date   2/8/2017
    !!
    !--------------------------------------------------------------------------------
    subroutine init(self)
        class(turbo_interface_steady_t),   intent(inout) :: self

        ! Set name, family
        call self%set_name('Steady Turbo Interface')
        call self%set_family('Inlet')

        ! Add functions
        call self%bcproperties%add('Pitch A', 'Required')
        call self%bcproperties%add('Pitch B', 'Required')

!        call self%bcproperties%add('Spatial Periodicity A', 'Required')
!        call self%bcproperties%add('Spatial Periodicity A', 'Required')

    end subroutine init
    !********************************************************************************





    !>  
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2018
    !!
    !!  @param[in]      worker  Interface for geometry, cache, integration, etc.
    !!  @param[inout]   prop    properties_t object containing equations and material_t objects
    !!
    !-------------------------------------------------------------------------------------------
    subroutine compute_bc_state(self,worker,prop,bc_comm)
        class(turbo_interface_steady_t),   intent(inout)   :: self
        type(chidg_worker_t),                       intent(inout)   :: worker
        class(properties_t),                        intent(inout)   :: prop
        type(mpi_comm),                             intent(in)      :: bc_comm


        ! Storage at quadrature nodes
        type(AD_D), allocatable, dimension(:)   ::                                                      &
            density_bc, mom1_bc, mom2_bc, mom3_bc, energy_bc, pressure_bc, vel1_bc, vel2_bc, vel3_bc,   &
            grad1_density_m, grad1_mom1_m, grad1_mom2_m, grad1_mom3_m, grad1_energy_m,                  &
            grad2_density_m, grad2_mom1_m, grad2_mom2_m, grad2_mom3_m, grad2_energy_m,                  &
            grad3_density_m, grad3_mom1_m, grad3_mom2_m, grad3_mom3_m, grad3_energy_m,                  &
            density_bar, vel1_bar, vel2_bar, vel3_bar, pressure_bar, c_bar

        type(AD_D), allocatable, dimension(:,:) ::                                                                      &
            density_check_real_gq, vel1_check_real_gq, vel2_check_real_gq, vel3_check_real_gq, pressure_check_real_gq,  &
            density_check_imag_gq, vel1_check_imag_gq, vel2_check_imag_gq, vel3_check_imag_gq, pressure_check_imag_gq

        type(AD_D)  :: pressure_avg, vel1_avg, vel2_avg, vel3_avg, density_avg, c_avg, T_avg, vmag

        type(AD_D), allocatable, dimension(:,:,:) ::                                                                                &
            density_check_real_m, vel1_check_real_m, vel2_check_real_m, vel3_check_real_m, pressure_check_real_m, c_check_real_m,   &
            density_check_imag_m, vel1_check_imag_m, vel2_check_imag_m, vel3_check_imag_m, pressure_check_imag_m, c_check_imag_m,   &
            density_hat_real_m, vel1_hat_real_m, vel2_hat_real_m, vel3_hat_real_m, pressure_hat_real_m, c_hat_real_m,               &
            density_hat_imag_m, vel1_hat_imag_m, vel2_hat_imag_m, vel3_hat_imag_m, pressure_hat_imag_m, c_hat_imag_m,               &
            density_check_real_p, vel1_check_real_p, vel2_check_real_p, vel3_check_real_p, pressure_check_real_p, c_check_real_p,   &
            density_check_imag_p, vel1_check_imag_p, vel2_check_imag_p, vel3_check_imag_p, pressure_check_imag_p, c_check_imag_p,   &
            density_hat_real_p, vel1_hat_real_p, vel2_hat_real_p, vel3_hat_real_p, pressure_hat_real_p, c_hat_real_p,               &
            density_hat_imag_p, vel1_hat_imag_p, vel2_hat_imag_p, vel3_hat_imag_p, pressure_hat_imag_p, c_hat_imag_p,               &
            density_hat_real_abs, vel1_hat_real_abs, vel2_hat_real_abs, vel3_hat_real_abs, pressure_hat_real_abs,                   &
            density_hat_imag_abs, vel1_hat_imag_abs, vel2_hat_imag_abs, vel3_hat_imag_abs, pressure_hat_imag_abs,                   &
            density_hat_real_gq, vel1_hat_real_gq, vel2_hat_real_gq, vel3_hat_real_gq, pressure_hat_real_gq,                        &
            density_hat_imag_gq, vel1_hat_imag_gq, vel2_hat_imag_gq, vel3_hat_imag_gq, pressure_hat_imag_gq,                        &
            density_grid_m, vel1_grid_m, vel2_grid_m, vel3_grid_m, pressure_grid_m, c_grid_m,                                       &
            density_grid_p, vel1_grid_p, vel2_grid_p, vel3_grid_p, pressure_grid_p, c_grid_p


        real(rk),       allocatable, dimension(:)   :: r, pitch
        real(rk),       allocatable, dimension(:)   :: PT, TT, n1, n2, n3, nmag
        integer(ik) :: ierr


        ! Get back pressure from function.
        pitch  = self%bcproperties%compute('Pitch', worker%time(),worker%coords())

        ! Interpolate interior solution to face quadrature nodes
        grad1_density_m = worker%get_field('Density'   , 'grad1', 'face interior')
        grad2_density_m = worker%get_field('Density'   , 'grad2', 'face interior')
        grad3_density_m = worker%get_field('Density'   , 'grad3', 'face interior')

        grad1_mom1_m    = worker%get_field('Momentum-1', 'grad1', 'face interior')
        grad2_mom1_m    = worker%get_field('Momentum-1', 'grad2', 'face interior')
        grad3_mom1_m    = worker%get_field('Momentum-1', 'grad3', 'face interior')

        grad1_mom2_m    = worker%get_field('Momentum-2', 'grad1', 'face interior')
        grad2_mom2_m    = worker%get_field('Momentum-2', 'grad2', 'face interior')
        grad3_mom2_m    = worker%get_field('Momentum-2', 'grad3', 'face interior')

        grad1_mom3_m    = worker%get_field('Momentum-3', 'grad1', 'face interior')
        grad2_mom3_m    = worker%get_field('Momentum-3', 'grad2', 'face interior')
        grad3_mom3_m    = worker%get_field('Momentum-3', 'grad3', 'face interior')
        
        grad1_energy_m  = worker%get_field('Energy'    , 'grad1', 'face interior')
        grad2_energy_m  = worker%get_field('Energy'    , 'grad2', 'face interior')
        grad3_energy_m  = worker%get_field('Energy'    , 'grad3', 'face interior')


        ! Store boundary gradient state. Grad(Q_bc). Do this here, before we
        ! compute any transformations for cylindrical.
        call worker%store_bc_state('Density'   , grad1_density_m, 'grad1')
        call worker%store_bc_state('Density'   , grad2_density_m, 'grad2')
        call worker%store_bc_state('Density'   , grad3_density_m, 'grad3')
                                                
        call worker%store_bc_state('Momentum-1', grad1_mom1_m,    'grad1')
        call worker%store_bc_state('Momentum-1', grad2_mom1_m,    'grad2')
        call worker%store_bc_state('Momentum-1', grad3_mom1_m,    'grad3')
                                                
        call worker%store_bc_state('Momentum-2', grad1_mom2_m,    'grad1')
        call worker%store_bc_state('Momentum-2', grad2_mom2_m,    'grad2')
        call worker%store_bc_state('Momentum-2', grad3_mom2_m,    'grad3')
                                                
        call worker%store_bc_state('Momentum-3', grad1_mom3_m,    'grad1')
        call worker%store_bc_state('Momentum-3', grad2_mom3_m,    'grad2')
        call worker%store_bc_state('Momentum-3', grad3_mom3_m,    'grad3')
                                                
        call worker%store_bc_state('Energy'    , grad1_energy_m,  'grad1')
        call worker%store_bc_state('Energy'    , grad2_energy_m,  'grad2')
        call worker%store_bc_state('Energy'    , grad3_energy_m,  'grad3')


!        ! Get primitive variables at (radius,theta,time) grid.
!        call self%get_q_interior(worker,bc_comm,    &
!                                 density_grid_m,    &
!                                 vel1_grid_m,       &
!                                 vel2_grid_m,       &
!                                 vel3_grid_m,       &
!                                 pressure_grid_m)
!        c_grid_m = sqrt(gam*pressure_grid_m/density_grid_m)

        ! Compute Fourier decomposition of temporal data at points
        ! on the spatial transform grid.
        !   q_check(r,theta,omega) = DFT(q)[time]
        call self%compute_temporal_dft(worker,bc_comm,                                  &
                                       density_grid_m,                                  &
                                       vel1_grid_m,                                     &
                                       vel2_grid_m,                                     &
                                       vel3_grid_m,                                     &
                                       pressure_grid_m,                                 &
                                       c_grid_m,                                        &
                                       density_check_real_m,  density_check_imag_m,     &
                                       vel1_check_real_m,     vel1_check_imag_m,        &
                                       vel2_check_real_m,     vel2_check_imag_m,        &
                                       vel3_check_real_m,     vel3_check_imag_m,        &
                                       pressure_check_real_m, pressure_check_imag_m,    &
                                       c_check_real_m,        c_check_imag_m)

        ! Compute Fourier decomposition in theta at set of radial 
        ! stations for each temporal mode:
        !   q_hat(r,m,omega) = DFT(q_check)[theta]
        call self%compute_spatial_dft(worker,bc_comm,                                &
                                      density_check_real_m,  density_check_imag_m,   &
                                      vel1_check_real_m,     vel1_check_imag_m,      &
                                      vel2_check_real_m,     vel2_check_imag_m,      &
                                      vel3_check_real_m,     vel3_check_imag_m,      &
                                      pressure_check_real_m, pressure_check_imag_m,  &
                                      c_check_real_m,        c_check_imag_m,         &
                                      density_hat_real_m,    density_hat_imag_m,     &
                                      vel1_hat_real_m,       vel1_hat_imag_m,        &
                                      vel2_hat_real_m,       vel2_hat_imag_m,        &
                                      vel3_hat_real_m,       vel3_hat_imag_m,        &
                                      pressure_hat_real_m,   pressure_hat_imag_m,    &
                                      c_hat_real_m,          c_hat_imag_m)




        ! Get spatio-temporal average at radial stations
        density_bar  = density_hat_real_m(:,1,1)
        vel1_bar     = vel1_hat_real_m(:,1,1)
        vel2_bar     = vel2_hat_real_m(:,1,1)
        vel3_bar     = vel3_hat_real_m(:,1,1)
        pressure_bar = pressure_hat_real_m(:,1,1)
        c_bar        = c_hat_real_m(:,1,1)


        ! Compute spatio-temporal average over entire surface
        call self%compute_boundary_average(worker,bc_comm,density_bar,vel1_bar,vel2_bar,vel3_bar,pressure_bar,c_bar, &
                                                          density_avg,vel1_avg,vel2_avg,vel3_avg,pressure_avg,c_avg)


        ! Get boundary condition Total Temperature, Total Pressure, and normal vector
        PT   = self%bcproperties%compute('Total Pressure',   worker%time(),worker%coords())
        TT   = self%bcproperties%compute('Total Temperature',worker%time(),worker%coords())

        ! Get user-input normal vector and normalize
        n1 = self%bcproperties%compute('Normal-1', worker%time(), worker%coords())
        n2 = self%bcproperties%compute('Normal-2', worker%time(), worker%coords())
        n3 = self%bcproperties%compute('Normal-3', worker%time(), worker%coords())

        !   Explicit allocation to handle GCC bug:
        !       GCC/GFortran Bugzilla Bug 52162 
        allocate(nmag(size(n1)), stat=ierr)
        if (ierr /= 0) call AllocationError

        nmag = sqrt(n1*n1 + n2*n2 + n3*n3)
        n1 = n1/nmag
        n2 = n2/nmag
        n3 = n3/nmag


        ! Override spatio-temporal mean according to specified total conditions
        T_avg = TT(1)*(pressure_avg/PT(1))**((gam-ONE)/gam)
        density_avg = pressure_avg/(T_avg*Rgas)
        vmag = sqrt(TWO*cp*(TT(1)-T_avg))
        vel1_avg = n1(1)*vmag
        vel2_avg = n2(1)*vmag
        vel3_avg = n3(1)*vmag

        ! Get exterior perturbation
        call self%get_q_exterior(worker,bc_comm,    &
                                 density_grid_p,    &
                                 vel1_grid_p,       &
                                 vel2_grid_p,       &
                                 vel3_grid_p,       &
                                 pressure_grid_p)

        ! Add space-time average
        density_grid_p  = density_grid_p  + density_avg
        vel1_grid_p     = vel1_grid_p     + vel1_avg
        vel2_grid_p     = vel2_grid_p     + vel2_avg
        vel3_grid_p     = vel3_grid_p     + vel3_avg
        pressure_grid_p = pressure_grid_p + pressure_avg
        c_grid_p = sqrt(gam*pressure_grid_p/density_grid_p)


        ! Compute Fourier decomposition of temporal data at points
        ! on the spatial transform grid.
        !   q_check(r,theta,omega) = DFT(q)[time]
        call self%compute_temporal_dft(worker,bc_comm,                                  &
                                       density_grid_p,                                  &
                                       vel1_grid_p,                                     &
                                       vel2_grid_p,                                     &
                                       vel3_grid_p,                                     &
                                       pressure_grid_p,                                 &
                                       c_grid_p,                                        &
                                       density_check_real_p,  density_check_imag_p,     &
                                       vel1_check_real_p,     vel1_check_imag_p,        &
                                       vel2_check_real_p,     vel2_check_imag_p,        &
                                       vel3_check_real_p,     vel3_check_imag_p,        &
                                       pressure_check_real_p, pressure_check_imag_p,    &
                                       c_check_real_p,        c_check_imag_p)



        ! Compute Fourier decomposition in theta at set of radial 
        ! stations for each temporal mode:
        !   q_hat(r,m,omega) = DFT(q_check)[theta]
        call self%compute_spatial_dft(worker,bc_comm,                                   &
                                      density_check_real_p,     density_check_imag_p,   &
                                      vel1_check_real_p,        vel1_check_imag_p,      &
                                      vel2_check_real_p,        vel2_check_imag_p,      &
                                      vel3_check_real_p,        vel3_check_imag_p,      &
                                      pressure_check_real_p,    pressure_check_imag_p,  &
                                      c_check_real_p,           c_check_imag_p,         &
                                      density_hat_real_p,       density_hat_imag_p,     &
                                      vel1_hat_real_p,          vel1_hat_imag_p,        &
                                      vel2_hat_real_p,          vel2_hat_imag_p,        &
                                      vel3_hat_real_p,          vel3_hat_imag_p,        &
                                      pressure_hat_real_p,      pressure_hat_imag_p,    &
                                      c_hat_real_p,             c_hat_imag_p)


        ! Compute q_abs = f(q_p,q_m)
        call self%compute_absorbing_inlet(worker,bc_comm,                               &
                                          density_hat_real_m,    density_hat_imag_m,    &
                                          vel1_hat_real_m,       vel1_hat_imag_m,       &
                                          vel2_hat_real_m,       vel2_hat_imag_m,       &
                                          vel3_hat_real_m,       vel3_hat_imag_m,       &
                                          pressure_hat_real_m,   pressure_hat_imag_m,   &
                                          c_hat_real_m,          c_hat_imag_m,          &
                                          density_hat_real_p,    density_hat_imag_p,    &
                                          vel1_hat_real_p,       vel1_hat_imag_p,       &
                                          vel2_hat_real_p,       vel2_hat_imag_p,       &
                                          vel3_hat_real_p,       vel3_hat_imag_p,       &
                                          pressure_hat_real_p,   pressure_hat_imag_p,   &
                                          c_hat_real_p,          c_hat_imag_p,          &
                                          density_hat_real_abs,  density_hat_imag_abs,  &
                                          vel1_hat_real_abs,     vel1_hat_imag_abs,     &
                                          vel2_hat_real_abs,     vel2_hat_imag_abs,     &
                                          vel3_hat_real_abs,     vel3_hat_imag_abs,     &
                                          pressure_hat_real_abs, pressure_hat_imag_abs)


        ! q_abs(r_gq) = I(q_abs(r_aux))
        call self%interpolate_raux_to_rgq(worker,bc_comm,   &
                                          density_hat_real_abs,  density_hat_imag_abs,  &
                                          vel1_hat_real_abs,     vel1_hat_imag_abs,     &
                                          vel2_hat_real_abs,     vel2_hat_imag_abs,     &
                                          vel3_hat_real_abs,     vel3_hat_imag_abs,     &
                                          pressure_hat_real_abs, pressure_hat_imag_abs, &
                                          density_hat_real_gq,   density_hat_imag_gq,   &
                                          vel1_hat_real_gq,      vel1_hat_imag_gq,      &
                                          vel2_hat_real_gq,      vel2_hat_imag_gq,      &
                                          vel3_hat_real_gq,      vel3_hat_imag_gq,      &
                                          pressure_hat_real_gq,  pressure_hat_imag_gq)



        ! Reconstruct primitive variables at quadrature nodes from absorbing Fourier modes
        ! via inverse transform.
        !   q_check(rgq,theta,omega) = IDFT(q_hat)[m]
        call self%compute_spatial_idft_gq(worker,bc_comm,                                   &
                                          density_hat_real_gq,      density_hat_imag_gq,    & 
                                          vel1_hat_real_gq,         vel1_hat_imag_gq,       &
                                          vel2_hat_real_gq,         vel2_hat_imag_gq,       &
                                          vel3_hat_real_gq,         vel3_hat_imag_gq,       &
                                          pressure_hat_real_gq,     pressure_hat_imag_gq,   &
                                          density_check_real_gq,    density_check_imag_gq,  &
                                          vel1_check_real_gq,       vel1_check_imag_gq,     &
                                          vel2_check_real_gq,       vel2_check_imag_gq,     &
                                          vel3_check_real_gq,       vel3_check_imag_gq,     &
                                          pressure_check_real_gq,   pressure_check_imag_gq)

        ! q(rgq,theta,t) = IDFT(q_check)[omega]
        call self%compute_temporal_idft_gq(worker,bc_comm,                                      &
                                           density_check_real_gq,    density_check_imag_gq,     & 
                                           vel1_check_real_gq,       vel1_check_imag_gq,        &
                                           vel2_check_real_gq,       vel2_check_imag_gq,        &
                                           vel3_check_real_gq,       vel3_check_imag_gq,        &
                                           pressure_check_real_gq,   pressure_check_imag_gq,    &
                                           density_bc, vel1_bc, vel2_bc, vel3_bc, pressure_bc)


        !
        ! Form conserved variables
        !
        density_bc = density_bc
        mom1_bc    = density_bc*vel1_bc
        mom2_bc    = density_bc*vel2_bc
        mom3_bc    = density_bc*vel3_bc
        energy_bc  = pressure_bc/(gam - ONE)  + HALF*(mom1_bc*mom1_bc + mom2_bc*mom2_bc + mom3_bc*mom3_bc)/density_bc


        !
        ! Account for cylindrical. Convert tangential momentum back to angular momentum.
        !
        if (worker%coordinate_system() == 'Cylindrical') then
            r = worker%coordinate('1','boundary')
            mom2_bc = mom2_bc * r
        end if


        !
        ! Store boundary condition state. q_bc
        !
        call worker%store_bc_state('Density'   , density_bc, 'value')
        call worker%store_bc_state('Momentum-1', mom1_bc,    'value')
        call worker%store_bc_state('Momentum-2', mom2_bc,    'value')
        call worker%store_bc_state('Momentum-3', mom3_bc,    'value')
        call worker%store_bc_state('Energy'    , energy_bc,  'value')



    end subroutine compute_bc_state
    !*********************************************************************************



    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   4/25/2018
    !!
    !------------------------------------------------------------------------------------
    subroutine get_q_exterior(self,worker,bc_comm, density, vel1, vel2, vel3, pressure)
        class(turbo_interface_steady_t),   intent(inout)   :: self
        type(chidg_worker_t),                       intent(inout)   :: worker
        type(mpi_comm),                             intent(in)      :: bc_comm
        type(AD_D),     allocatable,                intent(inout)   :: density(:,:,:)
        type(AD_D),     allocatable,                intent(inout)   :: vel1(:,:,:)
        type(AD_D),     allocatable,                intent(inout)   :: vel2(:,:,:)
        type(AD_D),     allocatable,                intent(inout)   :: vel3(:,:,:)
        type(AD_D),     allocatable,                intent(inout)   :: pressure(:,:,:)

        type(AD_D), allocatable, dimension(:,:,:) ::  &
            mom1, mom2, mom3, energy

        integer(ik) :: iradius, itime, nradius, ntheta, ntime, ierr


        ! Define Fourier space discretization to determine
        ! number of theta-samples are being taken
        nradius = size(self%r)
        ntheta  = size(self%theta,2)
        ntime   = worker%time_manager%ntime

        ! Allocate storage for discrete time instances
        allocate(density( nradius,ntheta,ntime),  &
                 mom1(    nradius,ntheta,ntime),  &
                 mom2(    nradius,ntheta,ntime),  &
                 mom3(    nradius,ntheta,ntime),  &
                 vel1(    nradius,ntheta,ntime),  &
                 vel2(    nradius,ntheta,ntime),  &
                 vel3(    nradius,ntheta,ntime),  &
                 energy(  nradius,ntheta,ntime),  &
                 pressure(nradius,ntheta,ntime), stat=ierr)
        if (ierr /= 0) call AllocationError


        ! Perform Fourier decomposition at each radial station.
        do iradius = 1,nradius
            do itime = 1,ntime
                ! Interpolate solution to physical_nodes at current radial station: [ntheta]
                density(iradius,:,itime) = worker%interpolate_field_general('Density',    donors=self%donor(iradius,:), donor_nodes=self%donor_node(iradius,:,:), itime=itime)
                mom1(iradius,:,itime)    = worker%interpolate_field_general('Momentum-1', donors=self%donor(iradius,:), donor_nodes=self%donor_node(iradius,:,:), itime=itime)
                mom2(iradius,:,itime)    = worker%interpolate_field_general('Momentum-2', donors=self%donor(iradius,:), donor_nodes=self%donor_node(iradius,:,:), itime=itime)
                mom3(iradius,:,itime)    = worker%interpolate_field_general('Momentum-3', donors=self%donor(iradius,:), donor_nodes=self%donor_node(iradius,:,:), itime=itime)
                energy(iradius,:,itime)  = worker%interpolate_field_general('Energy',     donors=self%donor(iradius,:), donor_nodes=self%donor_node(iradius,:,:), itime=itime)

                if (worker%coordinate_system() == 'Cylindrical') then
                    mom2(iradius,:,itime) = mom2(iradius,:,itime)/self%r(iradius)  ! convert to tangential momentum
                end if
            end do
        end do

        ! Compute velocities and pressure at each time
        vel1 = mom1/density
        vel2 = mom2/density
        vel3 = mom3/density
        pressure = (gam-ONE)*(energy - HALF*(mom1*mom1 + mom2*mom2 + mom3*mom3)/density)


        density  = ZERO
        vel1     = ZERO
        vel2     = ZERO
        vel3     = ZERO
        pressure = ZERO

!        do itime = 1,ntime
!            density(:,:,itime) = 0.001_rk*sin(-TWO*PI*self%theta + worker%time_manager%freqs(1)*worker%time_manager%times(itime))
!            !pressure(:,:,itime) = 100000._rk + 10._rk*sin(TWO*PI*self%theta + worker%time_manager%freqs(1)*worker%time_manager%times(itime))
!        end do



    end subroutine get_q_exterior
    !************************************************************************************












end module bc_state_turbo_interface_steady
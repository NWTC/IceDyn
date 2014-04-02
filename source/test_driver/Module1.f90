!..................................................................................................................................
! LICENSING
! Copyright (C) 2013  National Renewable Energy Laboratory
!
!    This file is part of Module1.
!
!    Module1 is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as
!    published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
!
!    This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
!    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
!
!    You should have received a copy of the GNU General Public License along with Module1.
!    If not, see <http://www.gnu.org/licenses/>.
!
!**********************************************************************************************************************************
!    Module 1 is a single-mass damped oscilator as described by the System 1 in Gasmi, et al (2013).    
! 
!    The module is given the module name ModuleName = Module1 and the abbreviated name ModName = Mod1. The mathematical
!    formulation of this module is a subset of the most general form permitted by the FAST modularization framework in tight
!    coupling, thus, the module is developed to support both loose and tight coupling (tight coupling for both time marching and
!    linearization).
!
!
!    References:
!
!    Gasmi, A., M. A. Sprague, J. M. Jonkman, and W. B. Jones, Numerical stability and accuracy of temporally coupled
!    multi-physics modules in wind turbine CAE tools. In proceedings of the 32nd ASME Wind Energy Symposium, 51st AIAA
!    Aerospace Sciences Meeting including the New Horizons Forum and Aerospace Exposition, Grapevine, TX, January 7-10,
!    2013.   Also published as NREL Report No. CP-2C00-57298.   Available in pdf format at:
!    http://www.nrel.gov/docs/fy13osti/57298.pdf
!
!**********************************************************************************************************************************
MODULE Module1

   USE Module1_Types
   USE NWTC_Library

   IMPLICIT NONE

   PRIVATE

   TYPE(ProgDesc), PARAMETER  :: Mod1_Ver = ProgDesc( 'Module1', 'v1.00.04', '13-February-2013' )

   ! ..... Public Subroutines ...................................................................................................

   PUBLIC :: Mod1_Init                           ! Initialization routine
   PUBLIC :: Mod1_End                            ! Ending routine (includes clean up)

   PUBLIC :: Mod1_UpdateStates                   ! Loose coupling routine for solving for constraint states, integrating
                                                 !   continuous states, and updating discrete states
   PUBLIC :: Mod1_CalcOutput                     ! Routine for computing outputs

   PUBLIC :: Mod1_CalcConstrStateResidual        ! Tight coupling routine for returning the constraint state residual
   PUBLIC :: Mod1_CalcContStateDeriv             ! Tight coupling routine for computing derivatives of continuous states
   PUBLIC :: Mod1_UpdateDiscState                ! Tight coupling routine for updating discrete states

CONTAINS
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE Mod1_Init( InitInp, u, p, x, xd, z, OtherState, y, Interval, InitOut, ErrStat, ErrMsg )
!
! This routine is called at the start of the simulation to perform initialization steps.
! The parameters are set here and not changed during the simulation.
! The initial states and initial guess for the input are defined.
!..................................................................................................................................

      TYPE(Mod1_InitInputType),       INTENT(IN   )  :: InitInp     ! Input data for initialization routine
      TYPE(Mod1_InputType),           INTENT(  OUT)  :: u           ! An initial guess for the input; input mesh must be defined
      TYPE(Mod1_ParameterType),       INTENT(  OUT)  :: p           ! Parameters
      TYPE(Mod1_ContinuousStateType), INTENT(  OUT)  :: x           ! Initial continuous states
      TYPE(Mod1_DiscreteStateType),   INTENT(  OUT)  :: xd          ! Initial discrete states
      TYPE(Mod1_ConstraintStateType), INTENT(  OUT)  :: z           ! Initial guess of the constraint states
      TYPE(Mod1_OtherStateType),      INTENT(  OUT)  :: OtherState  ! Initial other/optimization states
      TYPE(Mod1_OutputType),          INTENT(  OUT)  :: y           ! Initial system outputs (outputs are not calculated;
                                                                    !    only the output mesh is initialized)
      REAL(DbKi),                     INTENT(INOUT)  :: Interval    ! Coupling interval in seconds: the rate that
                                                                    !   (1) Mod1_UpdateStates() is called in loose coupling &
                                                                    !   (2) Mod1_UpdateDiscState() is called in tight coupling.
                                                                    !   Input is the suggested time from the glue code;
                                                                    !   Output is the actual coupling interval that will be used
                                                                    !   by the glue code.
      TYPE(Mod1_InitOutputType),      INTENT(  OUT)  :: InitOut     ! Output for initialization routine
      INTEGER(IntKi),                 INTENT(  OUT)  :: ErrStat     ! Error status of the operation
      CHARACTER(*),                   INTENT(  OUT)  :: ErrMsg      ! Error message if ErrStat /= ErrID_None


     ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = "" 

      ! Initialize the NWTC Subroutine Library

      CALL NWTC_Init( )

      ! Display the module information

      CALL DispNVD( Mod1_Ver )

      ! Define parameters here:

      p%m      = 3.43e6        ! mass of mass 1 (kg)
      p%c      = 1.95e5     ! damping of dashpot 1 (N/(m/s))
      p%k      = 2.74e7       ! stiffness of spring 1 (N/m)
      p%f      = 0.         ! applied force (constant) (N)  
      p%dt     = Interval   ! module time step (increment) (s)
      p%method = 2          ! integration method:  1 (RK4), 2 (AB4), or 3 (ABM4)

      p%verif  = 0          ! Flag for verification; 1 - verification test for coupling with Module 2; 
                            ! Module 2 must have cc = 0.01 and kc = 1.
                            ! see subroutine Mod1_CalcContStateDeriv for details.

      ! Check parameters for validity (general case) 
               
      IF ( EqualRealNos( p%m, 0.0_ReKi ) ) THEN
         ErrStat = ErrID_Fatal
         ErrMsg  = ' Error in Module1: Mass must be non-zero to avoid division-by-zero errors.'
         RETURN
      END IF

      IF ( p%method .ne. 1) then
        IF ( p%method .ne. 2) then
          IF ( p%method .ne. 3) then
             ErrStat = ErrID_Fatal
             ErrMsg  = ' Error in Module1: integration method must be 1 (RK4), 2 (AB4), or 3 (ABM4)'
             RETURN
          END IF
        END IF
      END IF

      ! Allocate OtherState if using multi-step method; initialize n

      if ( p%method .eq. 2) then       

         Allocate( OtherState%xdot(4), STAT=ErrStat )
         IF (ErrStat /= 0) THEN
            ErrStat = ErrID_Fatal
            ErrMsg = ' Error in Module1: could not allocate OtherStat%xdot.'
            RETURN
         END IF

      elseif ( p%method .eq. 3) then       

         Allocate( OtherState%xdot(4), STAT=ErrStat )
         IF (ErrStat /= 0) THEN
            ErrStat = ErrID_Fatal
            ErrMsg = ' Error in Module1: could not allocate OtherStat%xdot.'
            RETURN
         END IF

      endif

      ! Define initial system states here:

      x%q    = 0.   ! displacement 
      x%dqdt = 0.   ! velocity


      ! verification problems are set for quiescent initial conditions
      if (p%verif .gt. 0) then
         x%q    = 0.   ! displacement 
         x%dqdt = 0.   ! velocity
      endif

      ! Define initial guess for the system inputs here:

      u%fc   = 0.

      ! Define system output initializations (set up mesh) here:


      ! Define initialization-routine output here:

END SUBROUTINE Mod1_Init
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE Mod1_End( u, p, x, xd, z, OtherState, y, ErrStat, ErrMsg )
!
! This routine is called at the end of the simulation.
!..................................................................................................................................

      TYPE(Mod1_InputType),           INTENT(INOUT)  :: u           ! System inputs
      TYPE(Mod1_ParameterType),       INTENT(INOUT)  :: p           ! Parameters
      TYPE(Mod1_ContinuousStateType), INTENT(INOUT)  :: x           ! Continuous states
      TYPE(Mod1_DiscreteStateType),   INTENT(INOUT)  :: xd          ! Discrete states
      TYPE(Mod1_ConstraintStateType), INTENT(INOUT)  :: z           ! Constraint states
      TYPE(Mod1_OtherStateType),      INTENT(INOUT)  :: OtherState  ! Other/optimization states
      TYPE(Mod1_OutputType),          INTENT(INOUT)  :: y           ! System outputs
      INTEGER(IntKi),                 INTENT(  OUT)  :: ErrStat     ! Error status of the operation
      CHARACTER(*),                   INTENT(  OUT)  :: ErrMsg      ! Error message if ErrStat /= ErrID_None

      ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = "" 

      ! Place any last minute operations or calculations here:

      ! Close files here:

      ! Destroy the input data:

      CALL Mod1_DestroyInput( u, ErrStat, ErrMsg )

      ! Destroy the parameter data:

      CALL Mod1_DestroyParam( p, ErrStat, ErrMsg )

      ! Destroy the state data:

      CALL Mod1_DestroyContState(   x,           ErrStat, ErrMsg )
      CALL Mod1_DestroyDiscState(   xd,          ErrStat, ErrMsg )
      CALL Mod1_DestroyConstrState( z,           ErrStat, ErrMsg )
      CALL Mod1_DestroyOtherState(  OtherState,  ErrStat, ErrMsg )

      ! Destroy the output data:

      CALL Mod1_DestroyOutput( y, ErrStat, ErrMsg )


END SUBROUTINE Mod1_End
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE Mod1_UpdateStates( t, n, u, utimes, p, x, xd, z, OtherState, ErrStat, ErrMsg )
!
! Routine for solving for constraint states, integrating continuous states, and updating discrete states
! Constraint states are solved for input t; Continuous and discrete states are updated for t + p%dt
! (stepsize dt assumed to be in ModName parameter)
!..................................................................................................................................

      REAL(DbKi),                         INTENT(IN   ) :: t          ! Current simulation time in seconds
      INTEGER(IntKi),                     INTENT(IN   ) :: n          ! Current simulation time step n = 0,1,...
      TYPE(Mod1_InputType),               INTENT(IN   ) :: u(:)       ! Inputs at utimes
      REAL(DbKi),                         INTENT(IN   ) :: utimes(:)  ! Times associated with u(:), in seconds
      TYPE(Mod1_ParameterType),           INTENT(IN   ) :: p          ! Parameters
      TYPE(Mod1_ContinuousStateType),     INTENT(INOUT) :: x          ! Input: Continuous states at t;
                                                                      !   Output: Continuous states at t + Interval
      TYPE(Mod1_DiscreteStateType),       INTENT(INOUT) :: xd         ! Input: Discrete states at t;
                                                                      !   Output: Discrete states at t  + Interval
      TYPE(Mod1_ConstraintStateType),     INTENT(INOUT) :: z          ! Input: Constraint states at t;
                                                                      !   Output: Constraint states at t+dt
      TYPE(Mod1_OtherStateType),          INTENT(INOUT) :: OtherState ! Other/optimization states
      INTEGER(IntKi),                     INTENT(  OUT) :: ErrStat    ! Error status of the operation
      CHARACTER(*),                       INTENT(  OUT) :: ErrMsg     ! Error message if ErrStat /= ErrID_None

      ! local variables

      TYPE(Mod1_InputType)            :: u_interp  ! input interpolated from given u at utimes
      TYPE(Mod1_ContinuousStateType)  :: xdot      ! continuous state time derivative

      ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = "" 

      if (p%method .eq. 1) then
 
         CALL Mod1_RK4( t, n, u, utimes, p, x, xd, z, OtherState, ErrStat, ErrMsg )

      elseif (p%method .eq. 2) then

         CALL Mod1_AB4( t, n, u, utimes, p, x, xd, z, OtherState, ErrStat, ErrMsg )

      elseif (p%method .eq. 3) then

         CALL Mod1_ABM4( t, n, u, utimes, p, x, xd, z, OtherState, ErrStat, ErrMsg )

      else

         ErrStat = ErrID_Fatal
         ErrMsg  = ' Error in Mod1_UpdateStates: p%method must be 1 (RK4), 2 (AB4), or 3 (ABM4)'
         RETURN

      endif

      IF ( ErrStat >= AbortErrLev ) RETURN

END SUBROUTINE Mod1_UpdateStates
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE Mod1_CalcOutput( t, u, p, x, xd, z, OtherState, y, ErrStat, ErrMsg )
!
! Routine for computing outputs, used in both loose and tight coupling.
!..................................................................................................................................

      REAL(DbKi),                     INTENT(IN   )  :: t           ! Current simulation time in seconds
      TYPE(Mod1_InputType),           INTENT(IN   )  :: u           ! Inputs at t
      TYPE(Mod1_ParameterType),       INTENT(IN   )  :: p           ! Parameters
      TYPE(Mod1_ContinuousStateType), INTENT(IN   )  :: x           ! Continuous states at t
      TYPE(Mod1_DiscreteStateType),   INTENT(IN   )  :: xd          ! Discrete states at t
      TYPE(Mod1_ConstraintStateType), INTENT(IN   )  :: z           ! Constraint states at t
      TYPE(Mod1_OtherStateType),      INTENT(INOUT)  :: OtherState  ! Other/optimization states
      TYPE(Mod1_OutputType),          INTENT(INOUT)  :: y           ! Outputs computed at t (Input only so that mesh con-
                                                                    !   nectivity information does not have to be recalculated)
      INTEGER(IntKi),                 INTENT(  OUT)  :: ErrStat     ! Error status of the operation
      CHARACTER(*),                   INTENT(  OUT)  :: ErrMsg      ! Error message if ErrStat /= ErrID_None

      ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = "" 

      ! see Eqs. (12), (13)  in Gasmi et al. (2013)
      y%q    = x%q
      y%dqdt = x%dqdt

END SUBROUTINE Mod1_CalcOutput
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE Mod1_CalcContStateDeriv( t, u, p, x, xd, z, OtherState, xdot, ErrStat, ErrMsg )
!
! Routine for computing derivatives of continuous states.
!..................................................................................................................................

      REAL(DbKi),                     INTENT(IN   )  :: t           ! Current simulation time in seconds
      TYPE(Mod1_InputType),           INTENT(IN   )  :: u           ! Inputs at t
      TYPE(Mod1_ParameterType),       INTENT(IN   )  :: p           ! Parameters
      TYPE(Mod1_ContinuousStateType), INTENT(IN   )  :: x           ! Continuous states at t
      TYPE(Mod1_DiscreteStateType),   INTENT(IN   )  :: xd          ! Discrete states at t
      TYPE(Mod1_ConstraintStateType), INTENT(IN   )  :: z           ! Constraint states at t
      TYPE(Mod1_OtherStateType),      INTENT(INOUT)  :: OtherState  ! Other/optimization states
      TYPE(Mod1_ContinuousStateType), INTENT(  OUT)  :: xdot        ! Continuous state derivatives at t
      INTEGER(IntKi),                 INTENT(  OUT)  :: ErrStat     ! Error status of the operation
      CHARACTER(*),                   INTENT(  OUT)  :: ErrMsg      ! Error message if ErrStat /= ErrID_None

      ! local variables
      REAL(ReKi) :: force
      REAL(ReKi) :: cc
      REAL(ReKi) :: kc

      ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = "" 

      ! Compute the first time derivatives of the continuous states here:
      ! See Eqs. (11) and (13) in Gasmi et al (2013)

      ! The following is for verification purposes when Module 1 is coupled with Module 2 as described in Gasmi et al. (2013).
      ! However, the problem here is a forced one (not free vibration as in Gasmi et al.); it is critical that the 
      ! coupling damping and coupling stiffness of Module 2 is entered below (cc and kc), and in Module 2, 
      ! Mod2_Parameter%verif = 1.
      ! Under these conditions, the exact solutions for the two systems are
      ! 
      ! q1(t) = 1 - Cos(3.*t) 
      ! q2(t) = (1 - Cos(t))/2.
      !
      force = 0.
      if (p%verif .eq. 1) then  

         cc = 0.01
         kc = 1.0

         force = p%k*(1. - Cos(3.*t)) + 9.*p%m*Cos(3.*t) - kc*(-1. + (1. - Cos(t))/2. + Cos(3.*t)) -  &
                 cc*(Sin(t)/2. - 3.*Sin(3.*t)) + 3.*p%c*Sin(3.*t)

      endif

      xdot%q = x%dqdt

      xdot%dqdt = (- p%k * x%q - p%c * x%dqdt + u%fc + p%f + force) / p%m

END SUBROUTINE Mod1_CalcContStateDeriv
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE Mod1_UpdateDiscState( t, n, u, p, x, xd, z, OtherState, ErrStat, ErrMsg )
!
! Routine for updating discrete states
!..................................................................................................................................

      REAL(DbKi),                     INTENT(IN   )  :: t           ! Current simulation time in seconds
      INTEGER(IntKi),                 INTENT(IN   )  :: n           ! Current step of the simulation: t = n*Interval
      TYPE(Mod1_InputType),           INTENT(IN   )  :: u           ! Inputs at t
      TYPE(Mod1_ParameterType),       INTENT(IN   )  :: p           ! Parameters
      TYPE(Mod1_ContinuousStateType), INTENT(IN   )  :: x           ! Continuous states at t
      TYPE(Mod1_DiscreteStateType),   INTENT(INOUT)  :: xd          ! Input: Discrete states at t;
                                                                    !   Output: Discrete states at t + Interval
      TYPE(Mod1_ConstraintStateType), INTENT(IN   )  :: z           ! Constraint states at t
      TYPE(Mod1_OtherStateType),      INTENT(INOUT)  :: OtherState  ! Other/optimization states
      INTEGER(IntKi),                 INTENT(  OUT)  :: ErrStat     ! Error status of the operation
      CHARACTER(*),                   INTENT(  OUT)  :: ErrMsg      ! Error message if ErrStat /= ErrID_None

      ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = "" 

      ! Update discrete states here:

!      xd%DummyDiscState = 0.0

END SUBROUTINE Mod1_UpdateDiscState
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE Mod1_CalcConstrStateResidual( t, u, p, x, xd, z, OtherState, Z_residual, ErrStat, ErrMsg )
!
! Routine for solving for the residual of the constraint state functions
!..................................................................................................................................

      REAL(DbKi),                     INTENT(IN   )  :: t           ! Current simulation time in seconds
      TYPE(Mod1_InputType),           INTENT(IN   )  :: u           ! Inputs at t
      TYPE(Mod1_ParameterType),       INTENT(IN   )  :: p           ! Parameters
      TYPE(Mod1_ContinuousStateType), INTENT(IN   )  :: x           ! Continuous states at t
      TYPE(Mod1_DiscreteStateType),   INTENT(IN   )  :: xd          ! Discrete states at t
      TYPE(Mod1_ConstraintStateType), INTENT(IN   )  :: z           ! Constraint states at t (possibly a guess)
      TYPE(Mod1_OtherStateType),      INTENT(INOUT)  :: OtherState  ! Other/optimization states
      TYPE(Mod1_ConstraintStateType), INTENT(  OUT)  :: Z_residual  ! Residual of the constraint state functions using
                                                                    !     the input values described above
      INTEGER(IntKi),                 INTENT(  OUT)  :: ErrStat     ! Error status of the operation
      CHARACTER(*),                   INTENT(  OUT)  :: ErrMsg      ! Error message if ErrStat /= ErrID_None


      ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = "" 


         ! Solve for the residual of the constraint state functions here:

      Z_residual%DummyConstrState = 0

END SUBROUTINE Mod1_CalcConstrStateResidual
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE Mod1_RK4( t, n, u, utimes, p, x, xd, z, OtherState, ErrStat, ErrMsg )
!
! This subroutine implements the fourth-order Runge-Kutta Method (RK4) for numerically integrating ordinary differential equations:
!
!   Let f(t, x) = xdot denote the time (t) derivative of the continuous states (x). 
!   Define constants k1, k2, k3, and k4 as 
!        k1 = dt * f(t        , x_t        )
!        k2 = dt * f(t + dt/2 , x_t + k1/2 )
!        k3 = dt * f(t + dt/2 , x_t + k2/2 ), and
!        k4 = dt * f(t + dt   , x_t + k3   ).
!   Then the continuous states at t = t + dt are
!        x_(t+dt) = x_t + k1/6 + k2/3 + k3/3 + k4/6 + O(dt^5)
!
! For details, see:
! Press, W. H.; Flannery, B. P.; Teukolsky, S. A.; and Vetterling, W. T. "Runge-Kutta Method" and "Adaptive Step Size Control for 
!   Runge-Kutta." �16.1 and 16.2 in Numerical Recipes in FORTRAN: The Art of Scientific Computing, 2nd ed. Cambridge, England: 
!   Cambridge University Press, pp. 704-716, 1992.
!
!..................................................................................................................................

      REAL(DbKi),                     INTENT(IN   )  :: t           ! Current simulation time in seconds
      INTEGER(IntKi),                 INTENT(IN   )  :: n           ! time step number
      TYPE(Mod1_InputType),           INTENT(IN   )  :: u(:)        ! Inputs at t
      REAL(DbKi),                     INTENT(IN   )  :: utimes(:)   ! times of input
      TYPE(Mod1_ParameterType),       INTENT(IN   )  :: p           ! Parameters
      TYPE(Mod1_ContinuousStateType), INTENT(INOUT)  :: x           ! Continuous states at t on input at t + dt on output
      TYPE(Mod1_DiscreteStateType),   INTENT(IN   )  :: xd          ! Discrete states at t
      TYPE(Mod1_ConstraintStateType), INTENT(IN   )  :: z           ! Constraint states at t (possibly a guess)
      TYPE(Mod1_OtherStateType),      INTENT(INOUT)  :: OtherState  ! Other/optimization states
      INTEGER(IntKi),                 INTENT(  OUT)  :: ErrStat     ! Error status of the operation
      CHARACTER(*),                   INTENT(  OUT)  :: ErrMsg      ! Error message if ErrStat /= ErrID_None

      ! local variables
         
      TYPE(Mod1_ContinuousStateType)                 :: xdot        ! time derivatives of continuous states      
      TYPE(Mod1_ContinuousStateType)                 :: k1          ! RK4 constant; see above
      TYPE(Mod1_ContinuousStateType)                 :: k2          ! RK4 constant; see above 
      TYPE(Mod1_ContinuousStateType)                 :: k3          ! RK4 constant; see above 
      TYPE(Mod1_ContinuousStateType)                 :: k4          ! RK4 constant; see above 
      TYPE(Mod1_ContinuousStateType)                 :: x_tmp       ! Holds temporary modification to x
      TYPE(Mod1_InputType)                           :: u_interp    ! interpolated value of inputs 

      ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = "" 


      ! interpolate u to find u_interp = u(t)
      CALL Mod1_Input_ExtrapInterp( u, utimes, u_interp, t, ErrStat, ErrMsg )

      ! find xdot at t
      CALL Mod1_CalcContStateDeriv( t, u_interp, p, x, xd, z, OtherState, xdot, ErrStat, ErrMsg )

      k1%q    = p%dt * xdot%q
      k1%dqdt = p%dt * xdot%dqdt
  
      x_tmp%q    = x%q    + 0.5 * k1%q
      x_tmp%dqdt = x%dqdt + 0.5 * k1%dqdt

      ! interpolate u to find u_interp = u(t + dt/2)
      CALL Mod1_Input_ExtrapInterp(u, utimes, u_interp, t+0.5*p%dt, ErrStat, ErrMsg)

      ! find xdot at t + dt/2
      CALL Mod1_CalcContStateDeriv( t + 0.5*p%dt, u_interp, p, x_tmp, xd, z, OtherState, xdot, ErrStat, ErrMsg )

      k2%q    = p%dt * xdot%q
      k2%dqdt = p%dt * xdot%dqdt

      x_tmp%q    = x%q    + 0.5 * k2%q
      x_tmp%dqdt = x%dqdt + 0.5 * k2%dqdt

      ! find xdot at t + dt/2
      CALL Mod1_CalcContStateDeriv( t + 0.5*p%dt, u_interp, p, x_tmp, xd, z, OtherState, xdot, ErrStat, ErrMsg )
     
      k3%q    = p%dt * xdot%q
      k3%dqdt = p%dt * xdot%dqdt

      x_tmp%q    = x%q    + k3%q
      x_tmp%dqdt = x%dqdt + k3%dqdt

      ! interpolate u to find u_interp = u(t + dt)
      CALL Mod1_Input_ExtrapInterp(u, utimes, u_interp, t + p%dt, ErrStat, ErrMsg)

      ! find xdot at t + dt
      CALL Mod1_CalcContStateDeriv( t + p%dt, u_interp, p, x_tmp, xd, z, OtherState, xdot, ErrStat, ErrMsg )

      k4%q    = p%dt * xdot%q
      k4%dqdt = p%dt * xdot%dqdt

      x%q    = x%q    +  ( k1%q    + 2. * k2%q    + 2. * k3%q    + k4%q    ) / 6.      
      x%dqdt = x%dqdt +  ( k1%dqdt + 2. * k2%dqdt + 2. * k3%dqdt + k4%dqdt ) / 6.      

END SUBROUTINE Mod1_RK4
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE Mod1_AB4( t, n, u, utimes, p, x, xd, z, OtherState, ErrStat, ErrMsg )
!
! This subroutine implements the fourth-order Adams-Bashforth Method (RK4) for numerically integrating ordinary differential 
! equations:
!
!   Let f(t, x) = xdot denote the time (t) derivative of the continuous states (x). 
!
!   x(t+dt) = x(t)  + (dt / 24.) * ( 55.*f(t,x) - 59.*f(t-dt,x) + 37.*f(t-2.*dt,x) - 9.*f(t-3.*dt,x) )
!
!  See, e.g.,
!  http://en.wikipedia.org/wiki/Linear_multistep_method
!
!  or
!
!  K. E. Atkinson, "An Introduction to Numerical Analysis", 1989, John Wiley & Sons, Inc, Second Edition.
!
!..................................................................................................................................

      REAL(DbKi),                     INTENT(IN   )  :: t           ! Current simulation time in seconds
      INTEGER(IntKi),                 INTENT(IN   )  :: n           ! time step number
      TYPE(Mod1_InputType),           INTENT(IN   )  :: u(:)        ! Inputs at t
      REAL(DbKi),                     INTENT(IN   )  :: utimes(:)   ! times of input
      TYPE(Mod1_ParameterType),       INTENT(IN   )  :: p           ! Parameters
      TYPE(Mod1_ContinuousStateType), INTENT(INOUT)  :: x           ! Continuous states at t on input at t + dt on output
      TYPE(Mod1_DiscreteStateType),   INTENT(IN   )  :: xd          ! Discrete states at t
      TYPE(Mod1_ConstraintStateType), INTENT(IN   )  :: z           ! Constraint states at t (possibly a guess)
      TYPE(Mod1_OtherStateType),      INTENT(INOUT)  :: OtherState  ! Other/optimization states
      INTEGER(IntKi),                 INTENT(  OUT)  :: ErrStat     ! Error status of the operation
      CHARACTER(*),                   INTENT(  OUT)  :: ErrMsg      ! Error message if ErrStat /= ErrID_None


      ! local variables
      TYPE(Mod1_ContinuousStateType) :: xdot       ! Continuous state derivs at t
      TYPE(Mod1_InputType)           :: u_interp
         

      ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = "" 

      ! need xdot at t
      CALL Mod1_Input_ExtrapInterp(u, utimes, u_interp, t, ErrStat, ErrMsg)
      CALL Mod1_CalcContStateDeriv( t, u_interp, p, x, xd, z, OtherState, xdot, ErrStat, ErrMsg )

      if (n .le. 2) then

         OtherState%n = n

         OtherState%xdot ( 3 - n ) = xdot

         CALL Mod1_RK4(t, n, u, utimes, p, x, xd, z, OtherState, ErrStat, ErrMsg )

      else

         if (OtherState%n .lt. n) then

            OtherState%n = n
            OtherState%xdot(4)    = OtherState%xdot(3)
            OtherState%xdot(3)    = OtherState%xdot(2)
            OtherState%xdot(2)    = OtherState%xdot(1)

         elseif (OtherState%n .gt. n) then
 
            ErrStat = ErrID_Fatal
            ErrMsg = ' Backing up in time is not supported with a multistep method '
            RETURN

         endif

         OtherState%xdot ( 1 )     = xdot  ! make sure this is most up to date

         x%q    = x%q    + (p%dt / 24.) * ( 55.*OtherState%xdot(1)%q - 59.*OtherState%xdot(2)%q    + 37.*OtherState%xdot(3)%q  &
                                       - 9. * OtherState%xdot(4)%q )

         x%dqdt = x%dqdt + (p%dt / 24.) * ( 55.*OtherState%xdot(1)%dqdt - 59.*OtherState%xdot(2)%dqdt  &
                                          + 37.*OtherState%xdot(3)%dqdt  - 9.*OtherState%xdot(4)%dqdt )

      endif


END SUBROUTINE Mod1_AB4
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE Mod1_ABM4( t, n, u, utimes, p, x, xd, z, OtherState, ErrStat, ErrMsg )
!
! This subroutine implements the fourth-order Adams-Bashforth-Moulton Method (RK4) for numerically integrating ordinary 
! differential equations:
!
!   Let f(t, x) = xdot denote the time (t) derivative of the continuous states (x). 
!
!   Adams-Bashforth Predictor:
!   x^p(t+dt) = x(t)  + (dt / 24.) * ( 55.*f(t,x) - 59.*f(t-dt,x) + 37.*f(t-2.*dt,x) - 9.*f(t-3.*dt,x) )
!
!   Adams-Moulton Corrector:
!   x(t+dt) = x(t)  + (dt / 24.) * ( 9.*f(t+dt,x^p) + 19.*f(t,x) - 5.*f(t-dt,x) + 1.*f(t-2.*dt,x) )
!
!  See, e.g.,
!  http://en.wikipedia.org/wiki/Linear_multistep_method
!
!  or
!
!  K. E. Atkinson, "An Introduction to Numerical Analysis", 1989, John Wiley & Sons, Inc, Second Edition.
!
!..................................................................................................................................

      REAL(DbKi),                     INTENT(IN   )  :: t           ! Current simulation time in seconds
      INTEGER(IntKi),                 INTENT(IN   )  :: n           ! time step number
      TYPE(Mod1_InputType),           INTENT(IN   )  :: u(:)        ! Inputs at t
      REAL(DbKi),                     INTENT(IN   )  :: utimes(:)   ! times of input
      TYPE(Mod1_ParameterType),       INTENT(IN   )  :: p           ! Parameters
      TYPE(Mod1_ContinuousStateType), INTENT(INOUT)  :: x           ! Continuous states at t on input at t + dt on output
      TYPE(Mod1_DiscreteStateType),   INTENT(IN   )  :: xd          ! Discrete states at t
      TYPE(Mod1_ConstraintStateType), INTENT(IN   )  :: z           ! Constraint states at t (possibly a guess)
      TYPE(Mod1_OtherStateType),      INTENT(INOUT)  :: OtherState  ! Other/optimization states
      INTEGER(IntKi),                 INTENT(  OUT)  :: ErrStat     ! Error status of the operation
      CHARACTER(*),                   INTENT(  OUT)  :: ErrMsg      ! Error message if ErrStat /= ErrID_None

      ! local variables

      TYPE(Mod1_InputType)            :: u_interp        ! Continuous states at t
      TYPE(Mod1_ContinuousStateType)  :: x_pred          ! Continuous states at t
      TYPE(Mod1_ContinuousStateType)  :: xdot_pred       ! Continuous states at t

      ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = "" 

      CALL Mod1_CopyContState(x, x_pred, 0, ErrStat, ErrMsg)

      CALL Mod1_AB4( t, n, u, utimes, p, x_pred, xd, z, OtherState, ErrStat, ErrMsg )

      if (n .gt. 2) then

         CALL Mod1_Input_ExtrapInterp(u, utimes, u_interp, t + p%dt, ErrStat, ErrMsg)

         CALL Mod1_CalcContStateDeriv(t + p%dt, u_interp, p, x_pred, xd, z, OtherState, xdot_pred, ErrStat, ErrMsg )

         x%q    = x%q    + (p%dt / 24.) * ( 9. * xdot_pred%q +  19. * OtherState%xdot(1)%q - 5. * OtherState%xdot(2)%q &
                                          + 1. * OtherState%xdot(3)%q )
   
         x%dqdt = x%dqdt + (p%dt / 24.) * ( 9. * xdot_pred%dqdt + 19. * OtherState%xdot(1)%dqdt - 5. * OtherState%xdot(2)%dqdt &
                                          + 1. * OtherState%xdot(3)%dqdt )

      else

         x%q    = x_pred%q
         x%dqdt = x_pred%dqdt

      endif

END SUBROUTINE Mod1_ABM4
!----------------------------------------------------------------------------------------------------------------------------------
!..................................................................................................................................
!++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
! WE ARE NOT YET IMPLEMENTING THE JACOBIANS...
!++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
END MODULE Module1
!**********************************************************************************************************************************

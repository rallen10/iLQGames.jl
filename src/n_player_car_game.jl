struct NPlayerCarCost{nx, nu, xids, uids, TG<:SVector{5}, TR<:SMatrix{2,2},
                      TQs<:SMatrix{5,5}, TQg<:SMatrix{5,5}} <: PlayerCost{nx, nu}
    # an unique identifier for this player
    player_id::Int
    # the desired goal state for this player
    xg::TG
    # the time after which the goal state cost is active
    t_final::Float64
    # the cost for control
    R::TR
    # the state cost
    Qs::TQs
    # the cost for not being at the goal
    Qg::TQg
    # the avoidance radius
    r_avoid::Float64
    # soft constraints
    # the gravity constant
    gravity::Float64
    # bounds on the acceleration input
    des_acc_bounds::Tuple{Float64, Float64}
    # bounds on the velocity state
    des_v_bounds::Tuple{Float64, Float64}
    # bounds on the steering state
    des_steer_bounds::Tuple{Float64, Float64}
    # weight of the soft constraints
    w::Float64
end

xindex(c::NPlayerCarCost{nx, nu, xids}) where {nx, nu, xids} = xids
uindex(c::NPlayerCarCost{nx, nu, xids, uids}) where {nx, nu, xids, uids} = uids

function NPlayerCarCost{xids, uids}(;player_id::Int, xg::TG, t_final::Float64,
                                     R::TR = SMatrix{2,2}([.1 0.; 0. 1.]) * 10.,
                                     Qs::TQs = SMatrix{5,5}(diagm([0, 0, 0, 0.2, 2.])) * 20.,
                                     Qg::TQg = SMatrix{5,5}(diagm([1.,1.,1.,0.,0.]))*500,
                                     r_avoid = 1.2,
                                     gravity = 9.81,
                                     des_acc_bounds = (-2*gravity, 2*gravity),
                                     des_v_bounds = (-0.05, 2.),
                                     des_steer_bounds = (-deg2rad(30), deg2rad(30)),
                                     w = 50.) where {xids, uids, TG, TR, TQs, TQg}
    np = length(xids)
    nx = np * 5
    nu = np * 2
    return NPlayerCarCost{nx, nu, xids, uids, TG, TR, TQs, TQg}(player_id, xg,
                                                                t_final, R, Qs, Qg,
                                                                r_avoid, gravity,
                                                                des_acc_bounds,
                                                                des_v_bounds,
                                                                des_steer_bounds, w)
end

function iLQGames.quadraticize(pc::NPlayerCarCost, x::SVector, u::SVector,
                               t::AbstractFloat)
    nx = n_states(pc)
    nu = n_controls(pc)

    xi = xindex(pc)[pc.player_id]
    ui = uindex(pc)[pc.player_id]

    l = @MVector zeros(nx)
    Q = @MMatrix zeros(nx, nx)
    R = @MMatrix zeros(nu, nu)

    # the quadratic part of the control cost
    inputcost_quad!(R, pc.R, ui)
    # soft constraints on the control
    # - acceleration constraint
    softconstr_quad!(R, u, pc.des_acc_bounds..., pc.w, ui[2])

    # the quadratic part of the state cost
    statecost_quad!(Q, l, pc.Qs, x[xi], xi)
    # soft constraints on the state
    # - steering angle
    softconstr_quad!(Q, l, x, pc.des_steer_bounds..., pc.w, xi[4])
    # - speed
    softconstr_quad!(Q, l, x, pc.des_v_bounds..., pc.w, xi[5])
    # - proximity
    for (j, xj) in enumerate(xindex(pc))
        j != pc.player_id || continue
        xindex_ego, yindex_ego = xi[1], xi[2]
        xindex_other, yindex_other = xj[1], xj[2]
        proximitycost_quad!(Q, l, x, pc.r_avoid, pc.w, xindex_ego, yindex_ego,
                            xindex_other, yindex_other)
    end

    # the goal cost
    goalstatecost_quad!(Q, l, pc.Qg, pc.xg, x[xi], xi, t, pc.t_final)

    return QuadraticPlayerCost(SMatrix(Q), SVector(l), SMatrix(R))
end

function (pc::NPlayerCarCost)(x::SVector, u::SVector, t::Float64)
    # extract the states and inputs for this player
    xᵢ = x[xindex(pc)[pc.player_id]]
    uᵢ = u[uindex(pc)[pc.player_id]]
    # setup the cost: each player wan't to:
    cost = 0.
    # control:
    #   - reduce steering and acceleration/breaking effort
    # state:
    #  - avoid collisions
    #  - be close close to some target
    # control cost: only cares about own control
    cost += inputcost(pc.R, uᵢ)
    # running cost for states (e.g. large steering)
    cost += statecost(pc.Qs, xᵢ)

    # acceleration constraints
    cost += softconstr(uᵢ[2], pc.des_acc_bounds..., pc.w)
    # steering angle constraint
    cost += softconstr(xᵢ[4], pc.des_steer_bounds..., pc.w)
    # speed constraints
    cost += softconstr(xᵢ[5], pc.des_v_bounds..., pc.w)

    # proximity constraint
    xy_ego = xᵢ[@S(1:2)]
    for (j, xj) in enumerate(xindex(pc))
        j != pc.player_id || continue
        xy_other = x[xj[@S(1:2)]]
        cost += proximitycost(xy_ego, xy_other, pc.r_avoid, pc.w)
    end

    # goal state cost cost:
    cost += goalstatecost(pc.Qg, pc.xg, xᵢ, t, pc.t_final)

    return cost
end


function generate_nplayer_car_game(T_horizon::Float64, ΔT::Float64,
                                   goals::Vararg{SVector})
    np = length(goals)

    t_final = T_horizon - 1.5*ΔT
    h = Int(T_horizon/ΔT)

    # setup the dynamics
    dyn = ProductSystem(Tuple(Car5D{ΔT}(1.0) for i in 1:np))

    xids, uids = xindex(dyn), uindex(dyn)
    costs = SVector{np}([NPlayerCarCost{xids, uids}(player_id=i, xg=goals[i],
                                                    t_final=t_final) for i in 1:np])
    # construct the game
    g = GeneralGame{uids, h}(dyn, costs)
    return g
end

# TODO: FIXME write setup for 3 players

# ROSIE

Prototype for a ROS2 implementation in pure Erlang.

## Requirements:
    Erlang OTP 23 as minimum
    ROS2 foxy
    Cyclone DDS

Note: current implementation has been tested only against cyclone dds.

## Build

    $ rebar3 compile


## Tests against ROS2

### listener
    rebar3 shell --apps listener
    RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ros2 run demo_nodes_py talker

### talker
    rebar3 shell --apps talker
    RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ros2 run demo_nodes_py listener
### Turtle controller
Write commands on the shell to send them to the turtle on screen.

    # LAUNCH:
    rebar3 shell --apps turtle_controller
    RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ros2 run turtlesim turtlesim_node
    # USE:
    turtle ! go.
    turtle ! back.
    turtle ! right.
    turtle ! left.

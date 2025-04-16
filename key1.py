import os
import sys
import rclpy
from geometry_msgs.msg import Twist
from rclpy.qos import QoSProfile
import keyboard

BURGER_MAX_LIN_VEL = 0.8  # 修改为更高的速度
BURGER_MAX_ANG_VEL = 2.84

WAFFLE_MAX_LIN_VEL = 0.26
WAFFLE_MAX_ANG_VEL = 1.82

LIN_VEL_STEP_SIZE = 0.05
ANG_VEL_STEP_SIZE = 0.4

TURTLEBOT3_MODEL = os.environ.get('TURTLEBOT3_MODEL', 'burger')

msg = """
Control Your TurtleBot3!
---------------------------
Moving around:
        w
   a    s    d
        x

w/x : increase/decrease linear velocity (Burger : ~ 0.8, Waffle and Waffle Pi : ~ 0.26)
a/d : increase/decrease angular velocity (Burger : ~ 2.84, Waffle and Waffle Pi : ~ 1.82)

space key, s : force stop

CTRL-C to quit
"""

def print_vels(target_linear_velocity, target_angular_velocity):
    print('currently:\tlinear velocity {0:.2f}\t angular velocity {1:.2f}'.format(
        target_linear_velocity,
        target_angular_velocity))

def make_simple_profile(output, input, slop):
    if input > output:
        output = min(input, output + slop)
    elif input < output:
        output = max(input, output - slop)
    else:
        output = input
    return output

def constrain(input_vel, low_bound, high_bound):
    if input_vel < low_bound:
        return low_bound
    elif input_vel > high_bound:
        return high_bound
    else:
        return input_vel

def check_linear_limit_velocity(velocity):
    if TURTLEBOT3_MODEL == 'burger':
        return constrain(velocity, -BURGER_MAX_LIN_VEL, BURGER_MAX_LIN_VEL)
    else:
        return constrain(velocity, -WAFFLE_MAX_LIN_VEL, WAFFLE_MAX_LIN_VEL)

def check_angular_limit_velocity(velocity):
    if TURTLEBOT3_MODEL == 'burger':
        return constrain(velocity, -BURGER_MAX_ANG_VEL, BURGER_MAX_ANG_VEL)
    else:
        return constrain(velocity, -WAFFLE_MAX_ANG_VEL, WAFFLE_MAX_ANG_VEL)

def main():
    rclpy.init()
    qos = QoSProfile(depth=10)
    node = rclpy.create_node('teleop_keyboard')
    pub = node.create_publisher(Twist, '/cmd_vel', qos)

    target_linear_velocity = 0.0
    target_angular_velocity = 0.0
    control_linear_velocity = 0.0
    control_angular_velocity = 0.0

    print(msg)

    try:
        while rclpy.ok():
            if keyboard.is_pressed('w'):
                target_linear_velocity = check_linear_limit_velocity(target_linear_velocity + LIN_VEL_STEP_SIZE)
            elif keyboard.is_pressed('x'):
                target_linear_velocity = check_linear_limit_velocity(target_linear_velocity - LIN_VEL_STEP_SIZE)
            else:
                if abs(target_linear_velocity) < LIN_VEL_STEP_SIZE:
                    target_linear_velocity = 0.0
                else:
                    target_linear_velocity = make_simple_profile(target_linear_velocity, 0.0, LIN_VEL_STEP_SIZE)

            if keyboard.is_pressed('a'):
                target_angular_velocity = check_angular_limit_velocity(target_angular_velocity + ANG_VEL_STEP_SIZE)
            elif keyboard.is_pressed('d'):
                target_angular_velocity = check_angular_limit_velocity(target_angular_velocity - ANG_VEL_STEP_SIZE)
            else:
                if abs(target_angular_velocity) < ANG_VEL_STEP_SIZE:
                    target_angular_velocity = 0.0
                else:
                    target_angular_velocity = make_simple_profile(target_angular_velocity, 0.0, ANG_VEL_STEP_SIZE)

            if keyboard.is_pressed(' '):
                target_linear_velocity = 0.0
                target_angular_velocity = 0.0

            control_linear_velocity = make_simple_profile(
                control_linear_velocity,
                target_linear_velocity,
                LIN_VEL_STEP_SIZE)

            control_angular_velocity = make_simple_profile(
                control_angular_velocity,
                target_angular_velocity,
                ANG_VEL_STEP_SIZE)

            twist = Twist()
            twist.linear.x = control_linear_velocity
            twist.angular.z = control_angular_velocity

            pub.publish(twist)

            print_vels(control_linear_velocity, control_angular_velocity)

    except Exception as e:
        print(e)

    finally:
        twist = Twist()
        twist.linear.x = 0.0
        twist.angular.z = 0.0
        pub.publish(twist)

if __name__ == '__main__':
    main()
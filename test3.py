import rclpy
from rclpy.node import Node
from geometry_msgs.msg import TransformStamped
from tf2_ros import Buffer, TransformListener

class TFStaticListener(Node):
    def __init__(self):
        super().__init__('tf_static_listener')
        self.tf_buffer = Buffer()
        self.tf_listener = TransformListener(self.tf_buffer, self)
        self.timer = self.create_timer(1.0, self.print_depth_frame_info)

    def print_depth_frame_info(self):
        try:
            # 获取所有静态TF信息
            all_static_transforms = self.tf_buffer.all_frames_as_yaml()
            # 将YAML格式的字符串解析为字典
            transforms_dict = self.tf_buffer.all_frames_as_dict()

            # 遍历所有静态变换
            for frame_id, transform in transforms_dict.items():
                if "depth_frame" in transform.child_frame_id:
                    # 提取变换信息
                    translation = transform.transform.translation
                    rotation = transform.transform.rotation
                    # 按指定格式打印
                    print(f"child_frame_id: {transform.child_frame_id}, "
                          f"translation x,y,z=[{translation.x}, {translation.y}, {translation.z}], "
                          f"rotation x,y,z,w=[{rotation.x}, {rotation.y}, {rotation.z}, {rotation.w}]")
        except Exception as e:
            self.get_logger().error(f"Failed to get TF static info: {e}")

def main(args=None):
    rclpy.init(args=args)
    node = TFStaticListener()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()

if __name__ == '__main__':
    main()
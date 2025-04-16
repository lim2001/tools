import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile
from std_msgs.msg import String
from sensor_msgs.msg import Image
from geometry_msgs.msg import PoseStamped
import time
import threading

class TopicListener(Node):
    def __init__(self):
        super().__init__('topic_listener')

        # 用于存储话题的最后更新时间戳
        self.last_time = {}
        # 用于存储话题名与对应的帧数（计数）
        self.frame_counts = {}
        # 用于存储话题的QoS配置（防止丢失消息）
        self.qos_profile = QoSProfile(depth=10)

        # 启动话题刷新定时器
        self.timer = self.create_timer(1.0, self.refresh_topic_info)

        # 启动话题监听线程
        self.topic_info_thread = threading.Thread(target=self.listen_to_topics)
        self.topic_info_thread.start()

    def listen_to_topics(self):
        while rclpy.ok():
            # 获取当前系统的所有活跃话题
            topic_names_and_types = self.get_topic_names_and_types()

            for topic_name, topic_types in topic_names_and_types:
                # 处理每个话题的多个类型
                for topic_type in topic_types:
                    # 判断话题是否已经订阅
                    if topic_name not in self.frame_counts:
                        self.frame_counts[topic_name] = 0  # 初始化帧计数
                        self.last_time[topic_name] = time.time()  # 初始化时间戳

                        # 动态订阅每个话题
                        if topic_type == 'sensor_msgs/msg/Image':
                            self.create_subscription(Image, topic_name, self.callback_generic, self.qos_profile)
                        elif topic_type == 'geometry_msgs/msg/PoseStamped':
                            self.create_subscription(PoseStamped, topic_name, self.callback_generic, self.qos_profile)
                        elif topic_type == 'std_msgs/msg/String':
                            self.create_subscription(String, topic_name, self.callback_generic, self.qos_profile)
                        else:
                            # 默认处理其他类型的消息
                            self.create_subscription(String, topic_name, self.callback_generic, self.qos_profile)

    def callback_generic(self, msg):
        topic_name = self.get_topic_name(msg)
        self.update_frame_info(topic_name)

    def update_frame_info(self, topic_name):
        current_time = time.time()
        # 更新时间戳和帧计数
        self.frame_counts[topic_name] += 1
        self.last_time[topic_name] = current_time

    def get_topic_name(self, msg):
        # 根据消息类型动态获取话题名
        return str(msg._msgtype)  # 获取消息类型名称作为话题名（可以自定义更多信息）

    def refresh_topic_info(self):
        current_time = time.time()
        # 刷新话题信息
        for topic_name in list(self.frame_counts.keys()):
            # 计算帧率
            frame_rate = self.frame_counts[topic_name] / (current_time - self.last_time[topic_name])
            # 打印话题信息：话题名, frame_id, 帧率
            self.get_logger().info(f"Topic: {topic_name}, Frame rate: {frame_rate:.2f} Hz")
            # 重新设置计数器
            self.frame_counts[topic_name] = 0
            self.last_time[topic_name] = current_time


def main(args=None):
    rclpy.init(args=args)
    topic_listener = TopicListener()
    rclpy.spin(topic_listener)
    topic_listener.destroy_node()
    rclpy.shutdown()

if __name__ == '__main__':
    main()

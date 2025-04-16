import os

def find_rviz_files(start_dir):
    # 遍历指定目录及其子目录
    for root, dirs, files in os.walk(start_dir):
        for file in files:
            # 如果文件是 .rviz 配置文件
            if file.endswith('.rviz'):
                # 输出文件的完整路径
                print("rviz2 -d",os.path.join(root, file))

if __name__ == "__main__":
    # 获取当前目录
    current_dir = os.getcwd()
    # 调用函数搜索 .rviz 文件
    find_rviz_files(current_dir)

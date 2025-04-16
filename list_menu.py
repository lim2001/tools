"""
auto menu link --- list all of the python.py and its description in this folder
"""

# Copyright (c) 2025 Orbbec 3D Technology, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import os

class ListPythonFiles:
    def __init__(self):

        #self.package_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools')
        #self.package_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools')
        self.package_path = os.path.join(os.path.dirname(os.path.abspath(__file__)))
        if not os.path.exists(self.package_path):
            print(f"Directory not found at {self.package_path}")
            return

        self.list_python_files()

    def list_python_files(self):
        file_names = sorted(os.listdir(self.package_path))
        for file_name in file_names:
            if file_name.endswith('.py'):
                file_path = os.path.join(self.package_path, file_name)
                description = self.get_file_description(file_path)

                if description:
                    file_info = f"{file_name:<16}  -- {description}"
                else:
                    file_info = f"{file_name}"

                print(file_info)
    def get_file_description(self, file_path):
        try:
            with open(file_path, 'r') as f:
                lines = f.readlines()
                if len(lines) > 0 and lines[0].strip().startswith('"""'):
                    description = ''
                    for line in lines[1:]:
                        description += line.strip()
                        if line.strip().endswith('"""'):
                            break
                    return description.strip('"""').strip()
                elif len(lines) > 0 and lines[0].strip().startswith('#'):
                    return lines[0].strip('#').strip()
                else:
                    return None
        except Exception as e:
            print(f"Failed to read file {file_path}: {e}")
            return None

def main():
    ListPythonFiles()

if __name__ == '__main__':
    main()

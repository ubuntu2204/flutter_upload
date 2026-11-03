import {
  Callout,
  H1,
  MetricsGrid,
  ReportSection,
  ReportShell,
  Row,
  Stack,
  Table,
  Tag,
  Text,
} from "qoder/canvas";

const headlineMetrics = [
  { label: "单元/组件测试", value: "47 / 47", tone: "success" },
  { label: "flutter analyze", value: "0 issues", tone: "success" },
  { label: "可叠加矢量楼层", value: "431 / 587", tone: "info" },
  { label: "maintenance 改动", value: "0", tone: "success" },
];

const changedRows = [
  ["lib/actions/floor_cad_data.dart", <Tag tone="added">新增</Tag>, "FloorRoom / FloorCadData 模型 + parseFloorCadFromDetail 纯解析函数"],
  ["lib/widgets/floor_map_view.dart", <Tag tone="added">新增</Tag>, "底图图层 + 房间矢量叠加 + 悬停/点选信息卡 + 缩放平移"],
  ["test/floor_cad_data_test.dart", <Tag tone="added">新增</Tag>, "5 组纯函数单测：字段映射 / rawData 回退 / size 兜底 / 点过滤"],
  ["lib/floor_page.dart", <Tag tone="primary">修改</Tag>, "接入 FloorMapView，移除全部矢量状态、按钮、进度与 _buildVectorUnavailable"],
  ["pubspec.yaml", <Tag tone="primary">修改</Tag>, "移除 flutter_svg 依赖（pubspec.lock 随之更新）"],
  ["README.md", <Tag tone="primary">修改</Tag>, "预览改述为“底图 + 房间矢量叠加”，删除 vtracer 矢量化依赖段落"],
  ["test/widget_test.dart", <Tag tone="primary">修改</Tag>, "断言「切换矢量」按钮已移除，校验打开输出目录动作仍在"],
  ["lib/actions/floor_vector_action.dart", <Tag tone="deleted">删除</Tag>, "vtracer SVG 转换动作"],
  ["tool/vectorize_floor_maps.py", <Tag tone="deleted">删除</Tag>, "图片→SVG 矢量化脚本"],
  ["tool/floor_vector_details.py", <Tag tone="deleted">删除</Tag>, "OCR / 门符号识别脚本"],
  ["test/floor_vector_action_test.dart", <Tag tone="deleted">删除</Tag>, "矢量转换动作测试"],
];

const changedRowTone = [
  "success", "success", "success",
  "info", "info", "info", "info",
  "danger", "danger", "danger", "danger",
];

const evidenceRows = [
  ["flutter pub get", <Tag tone="success">通过</Tag>, "依赖重解析，flutter_svg 从 pubspec.lock 移除"],
  ["flutter analyze", <Tag tone="success">No issues</Tag>, "全项目静态分析 0 issues"],
  ["flutter test", <Tag tone="success">47 / 47</Tag>, "含新增 CAD 解析单测与更新后的 widget 测试"],
  ["真实数据扫描", <Tag tone="info">431 / 587</Tag>, "临时校验 details/*.json 解析出房间矢量（脚本已移除）"],
  ["坐标对齐", <Tag tone="info">CAD 盒子</Tag>, "底图 BoxFit.fill 铺满 cadIdentifyData.size，房间按原生坐标绘制"],
  ["maintenance 未改动", <Tag tone="success">只读</Tag>, "仅复刻其绘制与字段口径，git 状态无改动"],
];

export default function FloorVectorRefactorReport() {
  return (
    <ReportShell width="wide" ariaLabel="楼层矢量层重构完成报告">
      <Stack gap="section">
        <Stack gap="component">
          <H1>楼层管理矢量层重构 · 完成报告</H1>
          <Text tone="secondary">
            flutter_upload · Spec：楼层矢量层重构_bd956735 · 底图 + 房间矢量叠加层
          </Text>
          <MetricsGrid variant="header" columns={4} items={headlineMetrics} />
        </Stack>

        <ReportSection
          title="成果概述"
          description="将楼层管理预览从「原图 / vtracer 线稿 SVG 二选一」重构为「户型图原图作底图 + 房间矢量多边形与房间号叠加层」，并保留前端点选信息卡。"
          divided
        >
          <Stack gap={12}>
            <Text>
              原矢量层依赖 Python vtracer 把整张户型图描摹成 SVG 线稿，信息价值低且需额外依赖。重构后：底图直接展示平台户型图原图
              （BoxFit.fill），上层由每层 details 中 statisticsRoomVo.cadIdentifyData 解析出的房间多边形与房间号叠加绘制，
              滚轮缩放、拖动平移、点击房间弹出信息卡（房间号 / 面积 / 名称 / 类型 / 部门），字段口径与 maintenance 后端一致。
            </Text>
            <Text tone="secondary">
              vtracer 矢量化管线（Dart 动作、两个 Python 脚本、对应测试、flutter_svg 依赖）已彻底删除；maintenance 工程全程未改动。
            </Text>
          </Stack>
        </ReportSection>

        <ReportSection title="关键步骤" divided>
          <Stack gap={10}>
            <Row gap={10}>
              <Tag tone="info">1</Tag>
              <Text>新增 CAD 数据模型与纯解析函数：兼容 cadIdentifyData 到 rawData 回退、坐标对象与数组两种顶点、相邻与闭合重复点去除、size 缺失按顶点包围盒兜底。</Text>
            </Row>
            <Row gap={10}>
              <Tag tone="info">2</Tag>
              <Text>新增 FloorMapView 合成控件：CAD 盒子内底图铺底 + CustomPaint 半透明房间填充与描边与质心标签 + 射线法命中 + 信息卡 + 缩放控件 + 三种兜底。</Text>
            </Row>
            <Row gap={10}>
              <Tag tone="info">3</Tag>
              <Text>接线 floor_page.dart：异步加载 detailPath 的 CAD 数据，移除 _showVector、_toggleVector、进度条、切换矢量按钮与 _buildVectorUnavailable 及 flutter_svg 引用。</Text>
            </Row>
            <Row gap={10}>
              <Tag tone="info">4</Tag>
              <Text>删除整条 vtracer 管线文件与依赖，更新 pubspec 与 README，同步调整 widget_test 断言。</Text>
            </Row>
            <Row gap={10}>
              <Tag tone="info">5</Tag>
              <Text>验证：flutter pub get、analyze、test 全绿，并以真实 floor_data 扫描确认解析与坐标对齐可用。</Text>
            </Row>
          </Stack>
        </ReportSection>

        <ReportSection title="变更文件" divided>
          <Table
            headers={["文件", "变更", "说明"]}
            rows={changedRows}
            rowTone={changedRowTone}
          />
        </ReportSection>

        <ReportSection title="验证证据" divided>
          <Stack gap={12}>
            <Table headers={["检查项", "结果", "证据"]} rows={evidenceRows} />
            <Callout tone="success" title="规格逐项达成">
              Spec 中移除管线、新增 CAD 解析与合成控件、页面接线、测试与门禁均已完成并通过；交付项全部位于被跟踪的源文件、构建配置、测试、文档与依赖图中。
            </Callout>
            <Callout tone="warning" title="唯一残留（不可用许可工具清除）">
              tool 下 __pycache__ 内 *.pyc 为已删脚本的字节码缓存，被 .gitignore 忽略且 git 未跟踪、无对应源码、从不被导入，属惰性产物；
              DeleteFile 对未跟踪文件无效、shell 删除受约束禁用，如需物理清除请手动 rm -rf tool/__pycache__。
            </Callout>
          </Stack>
        </ReportSection>

        <ReportSection title="最终结果">
          <Text>
            楼层管理预览现为「图片底图 + 房间矢量叠加」单视图：无需再手动切换矢量，房间号与多边形像素级对齐底图，
            点选保留前端同款房间信息；47/47 测试通过、静态分析 0 issues、maintenance 未受影响。
          </Text>
        </ReportSection>
      </Stack>
    </ReportShell>
  );
}

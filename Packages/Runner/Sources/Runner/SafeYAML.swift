// 先用 libyaml 的事件流检查一遍，再交给 Yams 组装节点树。
//
// Yams.compose 递归组装节点，嵌套几百层就会在协作线程的小栈上溢出（实测 990 层 `[` 直接崩溃）；
// 别名展开后还可能让重复键检查耗费指数级时间。事件流是线性读取，先在这里限制层数、节点数并拒绝别名。
// CYaml 是 Yams 包内的 C 目标（libyaml），随 Yams 一起编译链接。
import CYaml
import Yams

public struct SafeYAMLError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 从 1 开始；读不到位置时为 nil。
    public let line: Int?
    /// 固定文字，不含文件内容，可以直接显示，也不会把 kubeconfig 里的凭据带进诊断。
    public let reason: String
    public var description: String { (line.map { "第 \($0) 行：" } ?? "") + reason }
}

public enum SafeYAML {
    /// 空文档返回 nil。只接受单个文档。
    public static func compose(_ source: String, maxDepth: Int = 16, maxNodes: Int = 20_000) throws -> Node? {
        try check(source, maxDepth: maxDepth, maxNodes: maxNodes)
        return try Yams.compose(yaml: source)
    }

    static func check(_ source: String, maxDepth: Int, maxNodes: Int) throws(SafeYAMLError) {
        let bytes = Array(source.utf8)
        let input = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(bytes.count, 1))
        _ = input.initialize(from: bytes)
        // libyaml 会保存指向 parser 自身和输入的指针，两者都放在堆上，不能移动。
        let parser = UnsafeMutablePointer<yaml_parser_t>.allocate(capacity: 1)
        yaml_parser_initialize(parser)
        yaml_parser_set_encoding(parser, YAML_UTF8_ENCODING)
        yaml_parser_set_input_string(parser, input.baseAddress, bytes.count)
        defer {
            yaml_parser_delete(parser)
            parser.deallocate()
            input.deallocate()
        }

        var depth = 0
        var nodes = 0
        var documents = 0
        while true {
            var event = yaml_event_t()
            guard yaml_parser_parse(parser, &event) == 1 else {
                throw SafeYAMLError(line: Int(parser.pointee.problem_mark.line) + 1, reason: "YAML 语法错误")
            }
            defer { yaml_event_delete(&event) }
            let line = Int(event.start_mark.line) + 1
            switch event.type {
            case YAML_STREAM_END_EVENT:
                return
            case YAML_DOCUMENT_START_EVENT:
                documents += 1
                guard documents == 1 else { throw SafeYAMLError(line: line, reason: "只能包含一个 YAML 文档") }
            case YAML_ALIAS_EVENT:
                throw SafeYAMLError(line: line, reason: "不支持 YAML 别名（*名称），请直接写出内容")
            case YAML_SCALAR_EVENT:
                nodes += 1
            case YAML_SEQUENCE_START_EVENT, YAML_MAPPING_START_EVENT:
                nodes += 1
                depth += 1
                guard depth <= maxDepth else { throw SafeYAMLError(line: line, reason: "嵌套超过 \(maxDepth) 层") }
            case YAML_SEQUENCE_END_EVENT, YAML_MAPPING_END_EVENT:
                depth -= 1
            default:
                break
            }
            guard nodes <= maxNodes else { throw SafeYAMLError(line: line, reason: "内容超过 \(maxNodes) 个节点") }
        }
    }
}

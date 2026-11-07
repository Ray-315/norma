import Foundation

/// Fixed method description, not a model-generated hypothesis or research claim.
public enum NumericalSmoke {
    public static let protocolID = "least-squares-five-points-v1"
    public static let question = "用 5 个数据点拟合直线 y = 2x + 1，并用另一种方法核对结果"
    public static let method = """
    本实验采用内置的验证方法，未调用模型生成研究思路。

    1. 使用五个已知数据点：(0, 1)、(1, 3)、(2, 5)、(3, 7)、(4, 9)，已知答案为 y = 2x + 1。
    2. 用最小二乘法的正规方程计算直线的斜率、截距和均方误差（MSE）。
    3. 再用中心化协方差公式独立计算，核对两种方法是否一致，并与已知答案比较。

    这是一项已知问题的小规模验证，用于检查实验执行和结果追溯，不涉及提出新假设或发现新规律。
    """
    public static let report = """
    已知问题验证：最小二乘直线拟合

    对直线 y = 2x + 1 上的五个数据点进行拟合。正规方程计算与采用中心化协方差公式的独立复现结果一致，并通过了与已知解析解的核对。

    本次完成了结果可复现性和实验方案一致性检查（I1、I2）；尚未完成文献引用核查和研究报告与代码的一致性审查（I3、I4）。

    本报告是内置数值验证的结果摘要，未调用模型撰写，不代表新的科研发现或完整论文评审。
    """
    public static let legacyReport = "Known solved numerical verification: five points on y = 2x + 1. Normal equations and an independent centered-covariance rerun agree. This is a connectivity/evidence smoke, not a scientific novelty claim or full paper audit."
    public static func matches(_ plan: ExperimentPlan?) -> Bool {
        plan?.protocolHash == Codec.hash(Data(protocolID.utf8))
    }
}

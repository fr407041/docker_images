class StripThinkingTransformer {
  static TransformerName = "strip-thinking";

  constructor() {
    this.name = "strip-thinking";
  }

  async transformRequestIn(request) {
    const next = { ...request };
    delete next.reasoning;
    delete next.thinking;
    delete next.enable_thinking;
    next.think = false;
    return next;
  }

  async transformResponseOut(response) {
    return response;
  }
}

module.exports = StripThinkingTransformer;

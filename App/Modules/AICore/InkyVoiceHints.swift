import Foundation

/// Vocabulary hints for on-device speech recognition of questions to Inky
/// (`SFSpeechRecognitionRequest.contextualStrings`). STEM words that general dictation
/// often mishears ("carbonyl" → "carbon ill", "asymptote" → "ask him to").
enum InkyVoiceHints {
    static let contextualStrings: [String] = [
        "Inky", "highlight", "circle", "star", "label", "fill in", "undo that", "explain why",
        // chemistry
        "carbonyl", "hydroxyl", "carboxylic acid", "ester", "ether", "amine", "amide", "aldehyde", "ketone",
        "alkene", "alkyne", "benzene", "phenol", "functional group", "molecule", "SMILES", "stereocenter",
        "enantiomer", "nucleophile", "electrophile", "Le Chatelier", "equilibrium", "titration", "molarity",
        "enthalpy", "entropy", "Gibbs free energy", "activation energy", "transition state",
        // math
        "asymptote", "derivative", "integral", "quadratic", "parabola", "vertex", "logarithm", "exponential",
        "sine", "cosine", "tangent", "hypotenuse", "Pythagoras", "slope", "intercept", "polynomial",
        // physics & bio
        "velocity", "acceleration", "displacement", "free-body diagram", "normal force", "friction", "torque",
        "mitochondrion", "mitochondria", "chloroplast", "ribosome", "metaphase", "anaphase", "telophase", "prophase",
    ]
}

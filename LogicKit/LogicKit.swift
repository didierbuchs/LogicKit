//
//  LogicKit.swift
//  LogicKit
//
//  Created by Dimitri Racordon on 07.02.17.
//  Copyright © 2017 University of Geneva. All rights reserved.
//

public protocol Term {

    // We can't make the Term conform to Equatable, as we need to use within
    // heterogeneous collections. Hence we can't have a safe requirements
    // (see WWDC 2015 - session 408). Similarly, we can't require conforming
    // types to implement the global equality operator (==), as the various
    // overloads would become ambiguous without a self requirement.
    func equals(_ other: Term) -> Bool

}


public protocol Superterm: Term {

    static func build(fromProperties properties: [(label: String?, value: Any)]) -> Self

}


public struct Variable: Term {

    public let name: String

    public func equals(_ other: Term) -> Bool {
        if other is Variable {
            return (other as! Variable).name == self.name
        }

        return false
    }

}

extension Variable: Hashable {

    public var hashValue: Int {
        return self.name.hashValue
    }

    public static func == (left: Variable, right: Variable) -> Bool {
        return left.name == right.name
    }

}


public struct Value<T: Equatable>: Term {

    fileprivate let value: T

    public init(_ val: T) {
        self.value = val
    }

    public func equals(_ other: Term) -> Bool {
        if let rhs = (other as? Value<T>) {
            return rhs.value == self.value
        }

        return false
    }

}

extension Value: Equatable {

    public static func == <T: Equatable>(lhs: Value<T>, rhs: Value<T>) -> Bool {
        return lhs.value == rhs.value
    }

}


public struct Unassigned: Term {

    public func equals(_ other: Term) -> Bool {
        return false
    }

}


public struct Substitution {

    fileprivate var storage = [Variable: Term]()

    public typealias Association = (variable: Variable, term: Term)

    subscript(_ key: Term) -> Term {
        // If the given key is a superterm, we have to walk its subterms.
        if let superterm = key as? Superterm {
            let mirror = Mirror(reflecting: superterm)
            let properties = mirror.children.map { label, value in
                return (value is Term)
                    ? (label: label, value: self[value as! Term])
                    : (label: label, value: value)
            }
            return type(of: superterm).build(fromProperties: properties)
        }

        // If the the given key isn't a variable, we can just give it back.
        guard let k = key as? Variable else {
            return key
        }

        if let rhs = self.storage[k] {
            // Continue walking in case the rhs is another variable, or a
            // superterm whose subterms should also be walked.
            return self[rhs]
        }

        // We give back the variable if is not associated.
        return key
    }

    func extended(with association: Association) -> Substitution {
        // TODO: Check for introduced circularity.
        var result = self
        result.storage[association.variable] = association.term
        return result
    }

    func unifying(_ u: Term, _ v: Term) -> Substitution? {
        let walkedU = self[u]
        let walkedV = self[v]

        // Terms that walk to equal values always unify, but add nothing to
        // the substitution.
        if walkedU.equals(walkedV) {
            return self
        }

        // Unifying a logic variable with some other term creates a new entry
        // in the substitution.
        if walkedU is Variable {
            return self.extended(with: (variable: walkedU as! Variable, term: walkedV))
        } else if walkedV is Variable {
            return self.extended(with: (variable: walkedV as! Variable, term: walkedU))
        }

        // If the walked values of u and of v are superterms, then unifying them
        // boils down to unifying their subterms.
        if (walkedU is Superterm) && (walkedV is Superterm) {
            return self.unifyingSubterms(walkedU as! Superterm, walkedV as! Superterm)
        }

        return nil
    }

    private func unifyingSubterms(_ u: Superterm, _ v: Superterm) -> Substitution? {
        // Unifying terms of different types always fail.
        guard type(of: u) == type(of: v) else {
            return nil
        }

        let reflectedU = Mirror(reflecting: u)
        let reflectedV = Mirror(reflecting: v)
        guard reflectedU.displayStyle == reflectedV.displayStyle else {
            return nil
        }

        // Unifying uninspectable types always fail, because there's now way
        // to decide whether u and v are equal.
        if (reflectedU.displayStyle != nil) {
            return nil
        }

        // Unifying terms of different lengths (e.g. [1, x, 3] and [1, x])
        // always fail.
        if reflectedU.children.count != reflectedV.children.count {
            return nil
        }

        var result: Substitution = self
        for (lhs, rhs) in zip(reflectedU.children, reflectedV.children) {
            if let su = lhs.value as? Term, let sv = rhs.value as? Term {
                if let unification = result.unifying(su, sv) {
                    result = unification
                } else {
                    // Unification fails when subterms can't be unified.
                    return nil
                }
            }
        }

        return result
    }

    func reifying(_ term: Term) -> Substitution {
        let walked = self[term]

        if walked is Variable {
            return self.extended(with: (variable: walked as! Variable, term: Unassigned()))
        }

        // If the walked value of the term is a superterm, its subterms should
        // be reified as well.
        if walked is Superterm {
            let mirror = Mirror(reflecting: walked)
            var result = self
            for child in mirror.children.flatMap({ $0.value as? Term }) {
                result = result.reifying(child)
            }

            return result
        }

        return self
    }

    func reified() -> Substitution {
        var result = self
        for variable in self.storage.keys {
            result = result.reifying(variable)
        }
        return result
    }

}

extension Substitution: Sequence {

    public func makeIterator() -> AnyIterator<Association> {
        var it = self.storage.makeIterator()

        return AnyIterator {
            if let (variable, term) = it.next() {
                return (variable: variable, term: self[term])
            }

            return nil
        }
    }

}


/// A struct containing a substitution and the name of the next unused logic
/// variable.
public struct State {

    let substitution: Substitution
    var nextUnusedName: String {
        return "_" + String(describing: self.nextId)
    }

    private let nextId: Int

    init(substitution: Substitution = Substitution(), nextId: Int = 0) {
        self.substitution = substitution
        self.nextId = nextId
    }

    func with(newSubstitution: Substitution) -> State {
        return State(substitution: newSubstitution, nextId: self.nextId)
    }

    func withNextNewName() -> State {
        return State(substitution: self.substitution, nextId: self.nextId + 1)
    }

}


public enum Stream {

    case empty
    indirect case mature(head: State, next: Stream)
    case immature(thunk: () -> Stream)

    // mplus
    func merge(_ other: Stream) -> Stream {
        switch self {
        case .empty:
            return other

        case .mature(head: let state, next: let next):
            return .mature(head: state, next: next.merge(other))

        case .immature(thunk: let thunk):
            return .immature {
                return other.merge(thunk())
            }
        }
    }

    // bind
    func map(_ goal: @escaping Goal) -> Stream {
        switch self {
        case .empty:
            return .empty

        case .mature(head: let head, next: let next):
            return goal(head).merge(next.map(goal))

        case .immature(thunk: let thunk):
            return .immature {
                return thunk().map(goal)
            }
        }
    }

    // pull
    func realize() -> Stream {
        switch self {
        case .empty:
            return .empty

        case .mature(head: _, next: _):
            return self

        case .immature(thunk: let thunk):
            return thunk().realize()
        }
    }

}

extension Stream: Sequence {

    public func makeIterator() -> AnyIterator<Substitution> {
        var it = self

        return AnyIterator {

            // Realize the iterated stream here, so that we its state is
            // computed as lazily as possible (i.e. when the iterator's next()
            // method is called).

            switch it.realize() {
            case .empty:
                // Return nothing for empty stream, ending the sequence.
                return nil

            case .mature(head: let state, next: let successor):
                // Return the realized substitution and advance the iterator.
                it = successor
                return state.substitution

            case .immature(thunk: _):
                assertionFailure("realize shouldn't produce immature streams")
            }

            return nil
        }
    }

}


/// Represents a function that encapsulates a logic program and which, given a
/// state, returns a stream of states for each way the program can succeed.
public typealias Goal = (State) -> Stream


infix operator ≡   : ComparisonPrecedence
infix operator === : ComparisonPrecedence

/// Creates a goal that unify two terms.
///
/// The goal takes an existing state and returns (as a lazy stream) either a
/// state with bindings for the variables in u and v (using unification), or
/// nothing at all if u and v cannot be unified.
func ≡ (u: Term, v: Term) -> Goal {
    return { state in
        if let s = state.substitution.unifying(u, v) {
            return .mature(head: state.with(newSubstitution: s), next: .empty)
        }

        return .empty
    }
}

/// Alternative for ≡(_:_:)
func === (u: Term, v: Term) -> Goal {
    return u ≡ v
}


/// Takes a goal constructor and returns a goal with fresh variables.
///
/// This function takes a *goal constructor* (i.e. a function), which accepts
/// a single variable as parameter, and returns a new goal for which the
/// variable is fresh.
func fresh(_ constructor: @escaping (Variable) -> Goal) -> Goal {
    return { state in
        constructor(Variable(name: state.nextUnusedName))(state.withNextNewName())
    }
}


/// Constructs a disjunction of goals.
func || (left: @escaping Goal, right: @escaping Goal) -> Goal {
    return { state in
        left(state).merge(right(state))
    }
}


/// Constructs a conjunction of goals.
func && (left: @escaping Goal, right: @escaping Goal) -> Goal {
    return { state in
        left(state).map(right)
    }
}


/// Takes a goal and returns a thunk that wraps it.
func delayed(_ goal: @escaping Goal) -> Goal {
    return { state in
        .immature { goal(state) }
    }
}

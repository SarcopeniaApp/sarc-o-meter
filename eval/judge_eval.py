#!/usr/bin/env python3
"""
Sarc-o-Meter · LLM-as-a-Judge Evaluation
═════════════════════════════════════════════════════════════════
Uses Llama-3.1-8B-Instruct as an independent judge to evaluate
Qwen2.5-3B's outputs on 5 metrics:

  1. Answer Relevance   — Is the response relevant to the user profile?
  2. Groundedness       — Are all claims grounded in the retrieved chunks?
  3. Answer Correctness — Are prescriptions clinically appropriate?
  4. Precision@K        — Of retrieved chunks, how many were useful?
  5. Recall@K           — Of all relevant chunks, how many were retrieved?

Reads the raw Qwen outputs from eval_results.json (produced by
evaluate_llm.py) so the generator model doesn't need to re-run.

Usage:
    python3 eval/judge_eval.py

Requirements:
    - Ollama running locally (`ollama serve`)
    - llama3.1:latest pulled (`ollama pull llama3.1`)
    - eval/eval_results.json exists (run evaluate_llm.py first)
"""

import json
import os
import re
import sys
import time
import requests
from dataclasses import dataclass, field
from typing import Optional

# ────────────────────────────────────────────────────────────────────────────
# Config
# ────────────────────────────────────────────────────────────────────────────

JUDGE_MODEL = "llama3.1:latest"
OLLAMA_URL = "http://localhost:11434/api/chat"
EVAL_DIR = os.path.dirname(__file__)
RESULTS_PATH = os.path.join(EVAL_DIR, "eval_results.json")
KB_PATH = os.path.join(
    EVAL_DIR, "..",
    "sarc-o-meter", "Features", "Screening", "knowledge_chunks.json"
)

# ────────────────────────────────────────────────────────────────────────────
# Data models (same as evaluate_llm.py)
# ────────────────────────────────────────────────────────────────────────────

@dataclass
class AssessmentResult:
    muscleMassStatus: str = "Not Assessed"
    strengthStatus: str = "Not Assessed"
    performanceStatus: str = "Not Assessed"
    obesityFlags: list = field(default_factory=list)
    redFlags: list = field(default_factory=list)
    overallRisk: str = "Unassessed (Incomplete Data)"
    workoutRestriction: str = "None (Standard Workout)"

@dataclass
class User:
    gender: Optional[str] = None       # "Male" | "Female"
    age: Optional[int] = None
    height: Optional[float] = None     # cm
    weight: Optional[float] = None     # kg
    calf: Optional[float] = None       # cm
    waist: Optional[float] = None      # cm
    chest: Optional[float] = None
    hip: Optional[float] = None
    hasRecentSurgeryOrHospitalization: bool = False
    hasHeartCondition: bool = False
    hasUncontrolledBP: bool = False
    hasBalanceOrDizziness: bool = False
    hasAcuteJointPainOrFracture: bool = False
    hasNeurologicalCondition: bool = False
    hasRoutineMedication: bool = False
    hasWalkingAid: bool = False
    sitToStandReps: Optional[int] = None
    stepUpReps: Optional[int] = None
    calfRaiseReps: Optional[int] = None


# ────────────────────────────────────────────────────────────────────────────
# Rule engine (same as evaluate_llm.py)
# ────────────────────────────────────────────────────────────────────────────

def evaluate_rule_engine(user: User) -> AssessmentResult:
    result = AssessmentResult()
    if user.hasRecentSurgeryOrHospitalization:
        result.redFlags.append("Operasi besar atau rawat inap baru-baru ini (< 3 bulan).")
    if user.hasHeartCondition:
        result.redFlags.append("Gangguan jantung (sering berdebar-debar atau riwayat diagnosis jantung).")
    if user.hasUncontrolledBP:
        result.redFlags.append("Tekanan darah tinggi tidak terkontrol.")
    if user.hasBalanceOrDizziness:
        result.redFlags.append("Sering kehilangan keseimbangan atau merasa pusing.")
    if user.hasAcuteJointPainOrFracture:
        result.redFlags.append("Nyeri sendi akut atau patah tulang belum sembuh.")
    if user.hasNeurologicalCondition:
        result.redFlags.append("Kondisi neurologis yang memengaruhi keseimbangan.")
    if user.hasRoutineMedication:
        result.redFlags.append("Mengonsumsi obat-obatan rutin (perlu pertimbangan interaksi obat & latihan).")
    if user.hasWalkingAid:
        result.redFlags.append("Menggunakan alat bantu jalan — latihan harus disesuaikan.")
    # Hard restriction: only conditions that directly impair safe exercise execution.
    has_hard_restriction = (user.hasHeartCondition or user.hasUncontrolledBP or
                            user.hasNeurologicalCondition or user.hasWalkingAid or
                            user.hasAcuteJointPainOrFracture)
    if has_hard_restriction:
        result.workoutRestriction = "Mobility & Balance Only (Requires Professional Clearance)"
    if user.calf is not None:
        is_low = (user.gender == "Male" and user.calf < 34.0) or \
                 (user.gender == "Female" and user.calf < 33.0)
        result.muscleMassStatus = "Abnormal / Low" if is_low else "Normal"
    if user.waist is not None:
        is_obese = (user.gender == "Male" and user.waist >= 90.0) or \
                   (user.gender == "Female" and user.waist >= 80.0)
        if is_obese:
            result.obesityFlags.append("Tanda Obesitas Sentral (Lingkar Pinggang)")
        if user.height and user.height > 0:
            whtr = user.waist / user.height
            if whtr > 0.5 and not any("Obesitas Sentral" in f for f in result.obesityFlags):
                result.obesityFlags.append("Tanda Obesitas Sentral (WHtR > 0,5)")
    SIT_MIN, STEP_MIN, CALF_MIN = 5, 4, 8
    if user.sitToStandReps is not None:
        low = user.sitToStandReps < SIT_MIN
        if user.calfRaiseReps is not None and user.calfRaiseReps < CALF_MIN:
            low = True
        result.strengthStatus = "Abnormal / Low" if low else "Normal"
    else:
        result.strengthStatus = "Abnormal / Low"
    if user.stepUpReps is not None:
        result.performanceStatus = "Abnormal / Low" if user.stepUpReps < STEP_MIN else "Normal"
    else:
        result.performanceStatus = "Abnormal / Low"
    if user.sitToStandReps is None or user.stepUpReps is None or user.calfRaiseReps is None:
        result.redFlags.append("Tidak dapat menyelesaikan sebagian tes latihan — perlu evaluasi langsung oleh fisioterapis/dokter.")
    is_low_mass = result.muscleMassStatus == "Abnormal / Low"
    is_low_str = result.strengthStatus == "Abnormal / Low"
    is_low_perf = result.performanceStatus == "Abnormal / Low"
    all_normal = (result.muscleMassStatus == "Normal" and
                  result.strengthStatus in ("Normal", "Not Assessed") and
                  result.performanceStatus in ("Normal", "Not Assessed"))
    if result.muscleMassStatus == "Not Assessed":
        result.overallRisk = "Unassessed (Incomplete Data)"
    elif is_low_mass and is_low_str and is_low_perf:
        result.overallRisk = "Severe Risk (Sarcopenia + Low Performance)"
    elif is_low_mass and (is_low_str or is_low_perf):
        result.overallRisk = "High Risk (Probable/Confirmed Sarcopenia)"
    elif is_low_mass or is_low_str or is_low_perf:
        result.overallRisk = "Mid Risk (Possible Sarcopenia)"
    elif all_normal:
        result.overallRisk = "Low Risk"
    else:
        result.overallRisk = "Unassessed (Incomplete Data)"
    return result


# ────────────────────────────────────────────────────────────────────────────
# Retrieval helpers
# ────────────────────────────────────────────────────────────────────────────

with open(KB_PATH, encoding="utf-8") as f:
    KNOWLEDGE_CHUNKS = json.load(f)

def relevant_tags(result: AssessmentResult):
    tags = {"general_exercise_principles", "nutrition"}
    if result.muscleMassStatus == "Abnormal / Low": tags.add("low_muscle_mass")
    if result.strengthStatus == "Abnormal / Low": tags.add("low_strength")
    if result.performanceStatus == "Abnormal / Low": tags.add("low_performance")
    if result.obesityFlags: tags.add("central_obesity")
    if result.redFlags: tags.add("contraindication")
    risk = result.overallRisk
    if risk.startswith("Low"): tags.add("risk_low")
    elif risk.startswith("Mid"): tags.add("risk_mid")
    elif risk.startswith("High"): tags.add("risk_high")
    elif risk.startswith("Severe"): tags.add("risk_severe")
    return tags

def max_chunks(result: AssessmentResult) -> int:
    risk = result.overallRisk
    if risk.startswith("Severe") or risk.startswith("High"):
        return 6
    if risk.startswith("Mid"):
        return 4
    return 3

def safety_critical_chunk_ids(result: AssessmentResult) -> set:
    if result.redFlags or result.overallRisk.startswith("Severe"):
        return {"kb_contraindication_01", "kb_risk_high_severe_01"}
    return set()

def retrieve(tags: set, limit: int, pinned_ids: set = None):
    if pinned_ids is None:
        pinned_ids = set()
    matching_chunks = [c for c in KNOWLEDGE_CHUNKS if set(c["tags"]) & tags]
    pinned = [c for c in matching_chunks if c["id"] in pinned_ids]
    remaining = [c for c in matching_chunks if c["id"] not in pinned_ids]
    return (pinned + remaining)[:limit]

def retrieve_all_relevant(tags: set):
    """All matching chunks (no limit) — for Recall@K."""
    return [c for c in KNOWLEDGE_CHUNKS if set(c["tags"]) & tags]


# ────────────────────────────────────────────────────────────────────────────
# Test personas (same as evaluate_llm.py)
# ────────────────────────────────────────────────────────────────────────────

TEST_PERSONAS = [
    {
        "name": "A — Healthy 45F (Low Risk)",
        "user": User(gender="Female", age=45, height=160.0, weight=58.0,
                     calf=35.0, waist=72.0,
                     sitToStandReps=8, stepUpReps=6, calfRaiseReps=12),
    },
    {
        "name": "B — 62M Possible Sarcopenia (Mid Risk)",
        "user": User(gender="Male", age=62, height=168.0, weight=65.0,
                     calf=32.0, waist=85.0,
                     sitToStandReps=6, stepUpReps=5, calfRaiseReps=10),
    },
    {
        "name": "C — 72F Low Muscle + Low Strength (High Risk)",
        "user": User(gender="Female", age=72, height=155.0, weight=52.0,
                     calf=30.5, waist=78.0,
                     sitToStandReps=3, stepUpReps=5, calfRaiseReps=6),
    },
    {
        "name": "D — 78M Severe (all abnormal + obesity)",
        "user": User(gender="Male", age=78, height=165.0, weight=72.0,
                     calf=31.0, waist=95.0,
                     sitToStandReps=2, stepUpReps=2, calfRaiseReps=4),
    },
    {
        "name": "E — 68F Red Flags (recent surgery + heart condition)",
        "user": User(gender="Female", age=68, height=157.0, weight=60.0,
                     calf=32.5, waist=82.0,
                     hasRecentSurgeryOrHospitalization=True,
                     hasHeartCondition=True,
                     sitToStandReps=4, stepUpReps=3, calfRaiseReps=7),
    },
    {
        "name": "F — 55M Multiple Red Flags + skipped exercises",
        "user": User(gender="Male", age=55, height=172.0, weight=80.0,
                     calf=33.0, waist=92.0,
                     hasBalanceOrDizziness=True,
                     hasAcuteJointPainOrFracture=True,
                     hasNeurologicalCondition=True,
                     sitToStandReps=None, stepUpReps=None, calfRaiseReps=None),
    },
    {
        "name": "G — 70F Severe + Balance/Dizziness + Skipped Tests",
        "user": User(gender="Female", age=70, height=152.0, weight=48.0,
                     calf=29.0, waist=76.0,
                     hasBalanceOrDizziness=True,
                     hasRoutineMedication=True,
                     sitToStandReps=None, stepUpReps=None, calfRaiseReps=None),
    },
]


# ────────────────────────────────────────────────────────────────────────────
# Ollama client
# ────────────────────────────────────────────────────────────────────────────

def call_judge(system: str, user_msg: str, temperature: float = 0.1) -> tuple[str, float]:
    """Call the judge model. Returns (response, latency_s)."""
    payload = {
        "model": JUDGE_MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user_msg},
        ],
        "stream": False,
        "options": {
            "temperature": temperature,
            "num_predict": 1024,
        },
    }
    t0 = time.time()
    resp = requests.post(OLLAMA_URL, json=payload, timeout=300)
    latency = time.time() - t0
    resp.raise_for_status()
    return resp.json()["message"]["content"], latency


def parse_judge_json(raw: str) -> dict | None:
    """Extract JSON from judge response (handles markdown fences, nested JSON)."""
    cleaned = raw.strip()
    # Remove markdown fences
    cleaned = re.sub(r"^```(?:json)?\s*\n?", "", cleaned)
    cleaned = re.sub(r"\n?```\s*$", "", cleaned)
    # Try to parse the full cleaned string first
    if "{" in cleaned:
        # Find the LAST top-level JSON object (the judge's reply)
        # by trying progressively from each '{'
        candidates = []
        depth = 0
        start = None
        for i, ch in enumerate(cleaned):
            if ch == '{':
                if depth == 0:
                    start = i
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0 and start is not None:
                    candidates.append(cleaned[start:i+1])
                    start = None
        # Try candidates in reverse (judge's reply is usually last)
        for candidate in reversed(candidates):
            try:
                parsed = json.loads(candidate)
                # Must have 'score' or 'precision' or 'recall' to be a judge reply
                if any(k in parsed for k in ('score', 'precision', 'recall', 'chunk_judgments')):
                    return parsed
            except json.JSONDecodeError:
                continue
    # Regex fallback: extract score if JSON fully failed
    score_match = re.search(r'"score"\s*:\s*(\d)', raw)
    if score_match:
        score = int(score_match.group(1))
        reasoning_match = re.search(r'"reasoning"\s*:\s*"([^"]+)"', raw)
        issues_match = re.findall(r'"issues"\s*:\s*\[([^\]]*)\]', raw)
        result = {"score": score, "reasoning": reasoning_match.group(1) if reasoning_match else "(extracted via regex)"}
        if issues_match:
            result["issues"] = [s.strip().strip('"') for s in issues_match[0].split(',') if s.strip().strip('"')]
        return result
    return None


# ────────────────────────────────────────────────────────────────────────────
# Judge prompts — one per metric
# ────────────────────────────────────────────────────────────────────────────

# ── Metric 1: Answer Relevance ──────────────────────────────────────────────

RELEVANCE_SYSTEM = """\
You are an expert evaluator assessing the relevance of an AI-generated \
exercise prescription for a sarcopenia screening app.

You will receive:
- The user's profile (age, gender, measurements, clinical history)
- The user's screening result (risk level, muscle/strength/performance status)
- The AI's response (a JSON exercise plan with insight)

Rate the RELEVANCE of the response on a 1-5 scale:
1 = Completely irrelevant (ignores user profile, generic boilerplate)
2 = Mostly irrelevant (addresses wrong risk level or ignores key profile data)
3 = Partially relevant (addresses some profile aspects, misses important ones)
4 = Mostly relevant (addresses most profile data, minor omissions)
5 = Highly relevant (fully personalized to age, gender, measurements, clinical history, risk level)

Reply ONLY with valid JSON:
{"score": <1-5>, "reasoning": "<brief explanation>"}"""


def build_relevance_prompt(user: User, result: AssessmentResult, response: str) -> str:
    return f"""\
USER PROFILE:
- Age: {user.age}, Gender: {user.gender}
- Height: {user.height} cm, Weight: {user.weight} kg
- Calf circumference: {user.calf} cm, Waist: {user.waist} cm
- Clinical flags: surgery={user.hasRecentSurgeryOrHospitalization}, \
heart_condition={user.hasHeartCondition}, uncontrolled_bp={user.hasUncontrolledBP}, \
balance_dizziness={user.hasBalanceOrDizziness}, \
joint_pain={user.hasAcuteJointPainOrFracture}, neuro={user.hasNeurologicalCondition}, \
routine_medication={user.hasRoutineMedication}, walking_aid={user.hasWalkingAid}

SCREENING RESULT:
- Overall risk: {result.overallRisk}
- Muscle mass: {result.muscleMassStatus}
- Strength: {result.strengthStatus}
- Performance: {result.performanceStatus}
- Red flags: {result.redFlags or 'None'}
- Obesity flags: {result.obesityFlags or 'None'}
- Workout restriction: {result.workoutRestriction}

AI RESPONSE:
{response}

Rate the relevance of this response to the user's specific profile and risk level."""


# ── Metric 2: Groundedness ──────────────────────────────────────────────────

GROUNDEDNESS_SYSTEM = """\
You are an expert evaluator checking whether an AI response is grounded \
in the provided knowledge base references. The AI is a sarcopenia \
screening assistant that should ONLY make claims supported by the \
given reference chunks.

You will receive:
- The retrieved knowledge chunks (the ONLY information the AI should use)
- The AI's response

Rate GROUNDEDNESS on a 1-5 scale:
1 = Mostly fabricated (majority of claims have no basis in the references)
2 = Poorly grounded (multiple significant claims not in references)
3 = Partially grounded (some claims supported, some fabricated)
4 = Mostly grounded (nearly all claims supported, minor unsupported details)
5 = Fully grounded (every factual claim traceable to the references or is a \
safe general exercise principle)

List any specific ungrounded claims you find.

Reply ONLY with valid JSON:
{"score": <1-5>, "reasoning": "<explanation>", "ungrounded_claims": ["<claim1>", ...]}"""


def build_groundedness_prompt(chunks: list, response: str) -> str:
    refs = "\n\n".join(
        f"[Chunk {i+1}: {c['id']}] (Source: {c['source']})\n{c['content']}"
        for i, c in enumerate(chunks)
    )
    return f"""\
RETRIEVED KNOWLEDGE CHUNKS (the ONLY allowed source of information):
{refs}

AI RESPONSE TO EVALUATE:
{response}

Check every factual claim in the AI response. Is each claim supported by \
the knowledge chunks above? List any ungrounded claims."""


# ── Metric 3: Answer Correctness ────────────────────────────────────────────

CORRECTNESS_SYSTEM = """\
You are a certified exercise physiologist evaluating the clinical \
appropriateness of an AI-generated exercise prescription for older adults \
at risk of sarcopenia.

You will receive:
- The user's screening result (risk level, flags, restrictions)
- The AI's exercise prescription (JSON with exercises, sets, reps, etc.)

Rate CLINICAL CORRECTNESS on a 1-5 scale:
1 = Dangerous (could cause harm — too intense for risk level, ignores contraindications)
2 = Inappropriate (wrong intensity level, missing critical safety notes)
3 = Acceptable (reasonable but not optimally tailored to risk level)
4 = Good (appropriate intensity, good safety notes, minor improvements possible)
5 = Excellent (perfectly matched to risk level, comprehensive safety, proper progression)

Key rules to check:
- Low risk → can be moderate-high intensity (3 sets × 10-15 reps)
- Mid risk → moderate intensity (2 sets × 8-12 reps)
- High risk → lower intensity (2 sets × 6-10 reps, longer rest)
- Severe risk → very low intensity (1 set × 4-8 reps, long rest, slow tempo)
- Red flags → MUST mention professional supervision, reduced intensity
- Mobility-only restriction / Severe Risk → MUST prescribe ONLY 1 gentle exercise (Calf Raise). DO NOT penalize for "lack of variety" or "insufficient exercises" if they are severe risk. A single exercise is the medically correct action.
- NEVER prescribe exercises outside: Sit to Stand, Step Up, Calf Raise

Reply ONLY with valid JSON:
{"score": <1-5>, "reasoning": "<explanation>", "issues": ["<issue1>", ...]}"""


def _extract_exercises_plain_text(response: str) -> str:
    """Convert the raw JSON response into plain-text exercise summary
    so the judge LLM doesn't get confused by nested JSON."""
    try:
        cleaned = response.strip()
        if '{' in cleaned:
            cleaned = cleaned[cleaned.index('{'):cleaned.rindex('}') + 1]
        parsed = json.loads(cleaned)
    except Exception:
        return response[:800]  # fallback: truncated raw

    lines = []
    insight = parsed.get('insight', '')
    if insight:
        lines.append(f"INSIGHT: {insight[:300]}")
    for ex in parsed.get('exercises', []):
        name = ex.get('exercise', '?')
        sets = ex.get('sets', '?')
        reps = ex.get('reps', '?')
        tempo = ex.get('tempo', '?')
        rest = ex.get('restSeconds', '?')
        safety = ex.get('safetyNotes', '—')
        prog = ex.get('progressionTip', '—')
        lines.append(f"EXERCISE: {name}")
        lines.append(f"  Sets: {sets}, Reps: {reps}, Tempo: {tempo}, Rest: {rest}s")
        lines.append(f"  Safety: {safety}")
        lines.append(f"  Progression: {prog}")
    ws = parsed.get('weeklySchedule', '')
    if ws:
        lines.append(f"WEEKLY SCHEDULE: {ws}")
    return '\n'.join(lines)


def build_correctness_prompt(result: AssessmentResult, response: str) -> str:
    plain = _extract_exercises_plain_text(response)
    return f"""\
SCREENING RESULT:
- Overall risk: {result.overallRisk}
- Muscle mass: {result.muscleMassStatus}
- Strength: {result.strengthStatus}
- Performance: {result.performanceStatus}
- Red flags: {result.redFlags or 'None'}
- Workout restriction: {result.workoutRestriction}

AI EXERCISE PRESCRIPTION (summarized):
{plain}

Evaluate whether this prescription is clinically appropriate and safe \
for someone with this risk profile."""


# ── Metric 4: Precision@K ───────────────────────────────────────────────────

PRECISION_SYSTEM = """\
You are evaluating the precision of a retrieval system for a sarcopenia \
screening app. The system retrieves knowledge chunks to help an AI \
generate exercise prescriptions.

You will receive:
- The user's screening profile
- The K retrieved knowledge chunks
- The AI's final response

For EACH retrieved chunk, judge whether it was USEFUL for generating \
the response (i.e., the response actually used or benefited from this chunk).

Reply ONLY with valid JSON:
{"chunk_judgments": [{"chunk_id": "<id>", "useful": true/false, "reason": "<why>"}], \
"precision": <float 0.0-1.0>}

precision = (number of useful chunks) / (total retrieved chunks)"""


def build_precision_prompt(user: User, result: AssessmentResult,
                           chunks: list, response: str) -> str:
    refs = "\n\n".join(
        f"[Chunk: {c['id']}] Tags: {c['tags']} | Source: {c['source']}\n{c['content']}"
        for c in chunks
    )
    return f"""\
USER PROFILE:
- Age: {user.age}, Gender: {user.gender}, Risk: {result.overallRisk}
- Muscle: {result.muscleMassStatus}, Strength: {result.strengthStatus}, \
Performance: {result.performanceStatus}
- Red flags: {result.redFlags or 'None'}
- Obesity flags: {result.obesityFlags or 'None'}

RETRIEVED CHUNKS (K={len(chunks)}):
{refs}

AI RESPONSE THAT USED THESE CHUNKS:
{response}

For each retrieved chunk, was it actually useful/used in the response?"""


# ── Metric 5: Recall@K ──────────────────────────────────────────────────────

RECALL_SYSTEM = """\
You are evaluating the recall of a retrieval system for a sarcopenia \
screening app. Given a user's screening profile, you must determine \
which knowledge chunks from the FULL knowledge base are relevant, then \
check how many of those were actually retrieved.

You will receive:
- The user's screening profile and risk level
- ALL chunks in the knowledge base (11 total)
- Which chunks were actually retrieved (K chunks)

For EACH chunk in the full KB, judge whether it is RELEVANT to this \
specific user's profile and risk level.

Reply ONLY with valid JSON:
{"chunk_judgments": [{"chunk_id": "<id>", "relevant": true/false, "reason": "<why>"}], \
"relevant_count": <int>, "retrieved_relevant_count": <int>, \
"recall": <float 0.0-1.0>}

recall = (retrieved chunks that are relevant) / (all relevant chunks in KB)"""


def build_recall_prompt(user: User, result: AssessmentResult,
                        retrieved_ids: list) -> str:
    all_chunks = "\n\n".join(
        f"[Chunk: {c['id']}] Tags: {c['tags']} | Source: {c['source']}\n{c['content']}"
        for c in KNOWLEDGE_CHUNKS
    )
    return f"""\
USER PROFILE:
- Age: {user.age}, Gender: {user.gender}, Risk: {result.overallRisk}
- Muscle: {result.muscleMassStatus}, Strength: {result.strengthStatus}, \
Performance: {result.performanceStatus}
- Red flags: {result.redFlags or 'None'}
- Obesity flags: {result.obesityFlags or 'None'}
- Workout restriction: {result.workoutRestriction}

ACTUALLY RETRIEVED CHUNK IDs: {retrieved_ids}

FULL KNOWLEDGE BASE ({len(KNOWLEDGE_CHUNKS)} chunks):
{all_chunks}

For each chunk, is it relevant to this specific user? Then compute recall."""


# ────────────────────────────────────────────────────────────────────────────
# Main evaluation loop
# ────────────────────────────────────────────────────────────────────────────

def run_judge_metric(metric_name: str, system: str, user_msg: str) -> dict:
    """Run one judge call and parse the result."""
    print(f"    Judging {metric_name}…", end=" ", flush=True)
    try:
        raw, latency = call_judge(system, user_msg)
        parsed = parse_judge_json(raw)
        if parsed:
            print(f"done ({latency:.1f}s)")
            parsed["_raw"] = raw
            parsed["_latency_s"] = round(latency, 1)
            return parsed
        else:
            print(f"⚠ JSON parse failed ({latency:.1f}s)")
            return {"_error": "JSON parse failed", "_raw": raw, "_latency_s": round(latency, 1)}
    except Exception as e:
        print(f"❌ {e}")
        return {"_error": str(e)}


def main():
    print("=" * 72)
    print("  Sarc-o-Meter · LLM-as-a-Judge Evaluation")
    print(f"  Judge model: {JUDGE_MODEL}")
    print(f"  Generator model: qwen2.5:3b (from cached eval_results.json)")
    print("=" * 72)

    # Check Ollama
    try:
        requests.get("http://localhost:11434/api/tags", timeout=5)
    except Exception:
        print("\n❌ Ollama is not running. Start it with: ollama serve")
        sys.exit(1)

    # Load previous Qwen outputs
    if not os.path.exists(RESULTS_PATH):
        print(f"\n❌ {RESULTS_PATH} not found. Run evaluate_llm.py first.")
        sys.exit(1)

    with open(RESULTS_PATH, encoding="utf-8") as f:
        qwen_results = json.load(f)

    all_judge_results = []

    for i, (persona_def, qwen_res) in enumerate(zip(TEST_PERSONAS, qwen_results)):
        name = persona_def["name"]
        user = persona_def["user"]
        raw_output = qwen_res["raw_output"]

        print(f"\n{'─' * 72}")
        print(f"  PERSONA {i+1}/{len(TEST_PERSONAS)}: {name}")
        print(f"{'─' * 72}")

        # Re-compute assessment & retrieval context
        result = evaluate_rule_engine(user)
        tags = relevant_tags(result)
        effective_limit = max_chunks(result)
        pinned = safety_critical_chunk_ids(result)
        retrieved = retrieve(tags, limit=effective_limit, pinned_ids=pinned)
        all_relevant = retrieve_all_relevant(tags)
        retrieved_ids = [c["id"] for c in retrieved]

        print(f"  Risk: {result.overallRisk}")
        print(f"  Retrieved: {retrieved_ids}")
        print(f"  All relevant: {[c['id'] for c in all_relevant]}")

        persona_scores = {"persona": name, "risk": result.overallRisk}

        # ── M1: Answer Relevance ──
        m1 = run_judge_metric(
            "Answer Relevance",
            RELEVANCE_SYSTEM,
            build_relevance_prompt(user, result, raw_output),
        )
        persona_scores["relevance"] = m1

        # ── M2: Groundedness ──
        m2 = run_judge_metric(
            "Groundedness",
            GROUNDEDNESS_SYSTEM,
            build_groundedness_prompt(retrieved, raw_output),
        )
        persona_scores["groundedness"] = m2

        # ── M3: Answer Correctness ──
        m3 = run_judge_metric(
            "Answer Correctness",
            CORRECTNESS_SYSTEM,
            build_correctness_prompt(result, raw_output),
        )
        persona_scores["correctness"] = m3

        # ── M4: Precision@K ──
        m4 = run_judge_metric(
            f"Precision@{len(retrieved)}",
            PRECISION_SYSTEM,
            build_precision_prompt(user, result, retrieved, raw_output),
        )
        persona_scores["precision"] = m4

        # ── M5: Recall@K ──
        m5 = run_judge_metric(
            f"Recall@{len(retrieved)}",
            RECALL_SYSTEM,
            build_recall_prompt(user, result, retrieved_ids),
        )
        persona_scores["recall"] = m5

        # Print summary for this persona
        print(f"\n  ┌─── Scores ───────────────────────────────────────┐")
        for metric in ["relevance", "groundedness", "correctness"]:
            score = persona_scores[metric].get("score", "?")
            reasoning = persona_scores[metric].get("reasoning", "—")[:80]
            print(f"  │ {metric:<16} {str(score):>3}/5  {reasoning}")
        prec = persona_scores["precision"].get("precision", "?")
        recall = persona_scores["recall"].get("recall", "?")
        print(f"  │ {'precision@K':<16} {prec}")
        print(f"  │ {'recall@K':<16} {recall}")
        print(f"  └─────────────────────────────────────────────────┘")

        # Print issues if any
        issues = persona_scores["correctness"].get("issues", [])
        if issues:
            print(f"  Correctness issues:")
            for issue in issues:
                print(f"    ⚠️  {issue}")

        ungrounded = persona_scores["groundedness"].get("ungrounded_claims", [])
        if ungrounded:
            print(f"  Ungrounded claims:")
            for claim in ungrounded:
                print(f"    📌 {claim}")

        all_judge_results.append(persona_scores)

    # ════════════════════════════════════════════════════════════════════
    # Summary
    # ════════════════════════════════════════════════════════════════════

    print(f"\n\n{'=' * 72}")
    print("  SUMMARY — LLM-as-a-Judge Results")
    print(f"{'=' * 72}")

    header = f"  {'Persona':<42} {'Relv':>4} {'Grnd':>4} {'Corr':>4} {'P@K':>6} {'R@K':>6}"
    print(header)
    print(f"  {'─' * 42} {'─' * 4} {'─' * 4} {'─' * 4} {'─' * 6} {'─' * 6}")

    # Collect numeric scores for averages
    scores_by_metric = {
        "relevance": [], "groundedness": [], "correctness": [],
        "precision": [], "recall": [],
    }

    for r in all_judge_results:
        rel = r["relevance"].get("score", "?")
        gnd = r["groundedness"].get("score", "?")
        cor = r["correctness"].get("score", "?")
        prec = r["precision"].get("precision", "?")
        rec = r["recall"].get("recall", "?")

        # Collect for averaging
        if isinstance(rel, (int, float)): scores_by_metric["relevance"].append(rel)
        if isinstance(gnd, (int, float)): scores_by_metric["groundedness"].append(gnd)
        if isinstance(cor, (int, float)): scores_by_metric["correctness"].append(cor)
        if isinstance(prec, (int, float)): scores_by_metric["precision"].append(prec)
        if isinstance(rec, (int, float)): scores_by_metric["recall"].append(rec)

        prec_str = f"{prec:.2f}" if isinstance(prec, float) else str(prec)
        rec_str = f"{rec:.2f}" if isinstance(rec, float) else str(rec)

        print(f"  {r['persona']:<42} {str(rel):>4} {str(gnd):>4} {str(cor):>4} {prec_str:>6} {rec_str:>6}")

    # Averages
    print(f"  {'─' * 42} {'─' * 4} {'─' * 4} {'─' * 4} {'─' * 6} {'─' * 6}")
    avgs = {}
    for metric, vals in scores_by_metric.items():
        avgs[metric] = sum(vals) / len(vals) if vals else 0
    print(f"  {'AVERAGE':<42} {avgs['relevance']:>4.1f} {avgs['groundedness']:>4.1f} "
          f"{avgs['correctness']:>4.1f} {avgs['precision']:>6.2f} {avgs['recall']:>6.2f}")

    # Save results
    output_path = os.path.join(EVAL_DIR, "judge_results.json")
    # Strip _raw from saved results to keep file manageable
    save_results = []
    for r in all_judge_results:
        entry = {"persona": r["persona"], "risk": r["risk"]}
        for metric in ["relevance", "groundedness", "correctness", "precision", "recall"]:
            entry[metric] = {k: v for k, v in r[metric].items() if k != "_raw"}
        save_results.append(entry)
    save_results.append({
        "averages": {k: round(v, 3) for k, v in avgs.items()}
    })
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(save_results, f, ensure_ascii=False, indent=2)
    print(f"\n  Full results saved to: {output_path}")
    print(f"{'=' * 72}")


if __name__ == "__main__":
    main()

import streamlit as st
import pandas as pd
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Vehicle Quality RCA Platform", layout="wide")

session = get_active_session()

st.title("🚗 Vehicle Quality Root Cause Analysis Platform")
st.caption("Real-time quality monitoring, root cause analysis, and 30-day failure forecasting")

# ---- Overall Fleet KPIs ----
st.header("Fleet-Wide 30-Day Risk Projection")

overall_df = session.table("VEHICLE_DB.VEHICLE_SCHEMA.VW_OVERALL_RISK_PROJECTION").to_pandas()

col1, col2, col3, col4 = st.columns(4)
col1.metric("Historical Failures (59 days)", int(overall_df["HISTORICAL_FAILURES"][0]))
col2.metric("Avg Daily Failure Rate", round(overall_df["AVG_DAILY_FAILURES"][0], 1))
col3.metric("Projected 30-Day Failures", overall_df["PROJECTED_30DAY_FAILURES"][0])
col4.metric("95% Confidence Range", f'{overall_df["LOWER_BOUND_95"][0]} – {overall_df["UPPER_BOUND_95"][0]}')

st.divider()

# ---- Supplier Risk ----
st.header("Supplier Risk Ranking")
supplier_df = session.table("VEHICLE_DB.VEHICLE_SCHEMA.VW_SUPPLIER_RISK_PROJECTION").to_pandas()
st.bar_chart(supplier_df.set_index("SUPPLIER_NAME")["PROJECTED_30DAY_FAILURES"])
st.dataframe(supplier_df, use_container_width=True)

st.divider()

# ---- Part Risk ----
st.header("Part-Level Risk Ranking (Top 10)")
part_df = session.table("VEHICLE_DB.VEHICLE_SCHEMA.VW_PART_RISK_PROJECTION").to_pandas()
top_parts = part_df.sort_values("PROJECTED_30DAY_FAILURES", ascending=False).head(10)
st.bar_chart(top_parts.set_index("PART_NUMBER")["PROJECTED_30DAY_FAILURES"])
st.dataframe(top_parts, use_container_width=True)

st.divider()

# ---- Battery Chemistry Risk ----
st.header("Battery Chemistry Risk")
battery_df = session.table("VEHICLE_DB.VEHICLE_SCHEMA.VW_BATTERY_TYPE_RISK_PROJECTION").to_pandas()
st.bar_chart(battery_df.set_index("BATTERY_TYPE_NAME")["PROJECTED_30DAY_FAILURES"])
st.dataframe(battery_df, use_container_width=True)


import json
import os
import requests

st.divider()
st.header("💬 Ask the Vehicle Quality RCA Analyst")
st.caption("Powered by Cortex Analyst — ask questions in plain English about quality, risk, and forecasts")

SEMANTIC_VIEW = "VEHICLE_DB.VEHICLE_SCHEMA.VEHICLE_QUALITY_SV"

def get_token() -> str:
    with open("/snowflake/session/token", "r") as f:
        return f.read()

def call_cortex_analyst(question: str):
    host = os.getenv("SNOWFLAKE_HOST")
    url = f"https://{host}/api/v2/cortex/analyst/message"
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Authorization": f"Bearer {get_token()}",
        "X-Snowflake-Authorization-Token-Type": "OAUTH",
    }
    request_body = {
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": question}]}
        ],
        "semantic_view": SEMANTIC_VIEW,
    }
    resp = requests.post(url, headers=headers, data=json.dumps(request_body), timeout=50)
    if resp.status_code >= 400:
        return None, resp.text
    return resp.json(), None

if "chat_messages" not in st.session_state:
    st.session_state.chat_messages = []

for msg in st.session_state.chat_messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["display"])

if question := st.chat_input("Ask about supplier risk, part failures, forecasts..."):
    st.session_state.chat_messages.append({"role": "user", "display": question})
    with st.chat_message("user"):
        st.markdown(question)

    with st.chat_message("assistant"):
        with st.spinner("Analyzing..."):
            result, error = call_cortex_analyst(question)

        if error:
            st.error(f"Error: {error}")
            st.session_state.chat_messages.append({"role": "assistant", "display": f"Error: {error}"})
        else:
            content_blocks = result.get("message", {}).get("content", [])
            display_text = ""

            for block in content_blocks:
                if block["type"] == "text":
                    display_text += block["text"] + "\n\n"
                    st.markdown(block["text"])
                elif block["type"] == "sql":
                    sql_query = block["statement"]
                    st.code(sql_query, language="sql")
                    try:
                        query_df = session.sql(sql_query).to_pandas()
                        st.dataframe(query_df, use_container_width=True)
                        display_text += f"\n(Ran query, {len(query_df)} rows returned)"
                    except Exception as e:
                        st.error(f"Query execution failed: {e}")
                elif block["type"] == "suggestions":
                    st.info("Try asking: " + " | ".join(block.get("suggestions", [])))

            st.session_state.chat_messages.append({"role": "assistant", "display": display_text})
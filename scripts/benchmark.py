from openai import OpenAI
from litellm import completion_cost
import time
import click
from tqdm import tqdm
from tabulate import tabulate
from termcolor import colored
import os
from dotenv import load_dotenv

questions = ["Can you tell me a story?", "What are 5 good business ideas?"]

load_dotenv()

base_url = os.getenv("BASE_URL")  # Litellm proxy base url
api_key = os.getenv("API_KEY")  # Litellm proxy api key

models = os.getenv("MODELS").split(
    ","
)  # List of models to benchmark. Values should be subset of model ids from your config.yaml

# List of questions to benchmark (replace with your questions)

# Enter your system prompt here
system_prompt = """
You are LiteLLMs helpful assistant
"""


@click.command()
@click.option(
    "--system-prompt",
    default="You are a helpful assistant that can answer questions.",
    help="System prompt for the conversation.",
)
def main(system_prompt):
    client = OpenAI(base_url=base_url, api_key=api_key)

    for question in questions:
        data = []  # Data for the current question

        with tqdm(total=len(models)) as pbar:
            for model in models:
                colored_description = colored(
                    f"Running question: {question} for model: {model}", "green"
                )
                pbar.set_description(colored_description)
                start_time = time.time()

                response = client.chat.completions.create(
                    model=model,
                    max_tokens=500,
                    messages=[
                        {"role": "system", "content": system_prompt},
                        {"role": "user", "content": question},
                    ],
                ).model_dump()

                end = time.time()
                total_time = end - start_time
                cost = completion_cost(completion_response=response)
                raw_response = response["choices"][0]["message"]["content"]

                data.append(
                    {
                        "Model": colored(model, "light_blue"),
                        "Response": raw_response,  # Colorize the response
                        "ResponseTime": colored(f"{total_time:.2f} seconds", "red"),
                        "Cost": colored(f"${cost:.6f}", "green"),  # Colorize the cost
                    }
                )

                pbar.update(1)

        # Separate headers from the data
        headers = ["Model", "Response", "Response Time (seconds)", "Cost ($)"]
        colwidths = [15, 80, 15, 10]

        # Create a nicely formatted table for the current question
        table = tabulate(
            [list(d.values()) for d in data],
            headers,
            tablefmt="grid",
            maxcolwidths=colwidths,
        )

        # Print the table for the current question
        colored_question = colored(question, "green")
        click.echo(f"\nBenchmark Results for '{colored_question}':")
        click.echo(table)  # Display the formatted table


if __name__ == "__main__":
    main()

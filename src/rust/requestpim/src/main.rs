use std::str;
use std::process::Command;

use clap::Parser;
use serde::Deserialize;
use serde_json::Value;
use reqwest::blocking::Client;
use inquire::{MultiSelect, Confirm};


#[derive(Parser)]
#[command(version, about, author, long_about = None)]
struct Cli {
    #[arg(short, long, value_name = "ROLES", help = "Comma separated list of PIM role names")]
    pim_roles: Option<String>,

    #[arg(short, long, value_name = "REASON", help = "Provide a reason for the request.")]
    reason: Option<String>,

    #[arg(short, long, help = "Suppress any yes/no prompts.")]
    yes_to_all: Option<bool>,
}


#[derive(Debug, Deserialize)]
struct Role {
    id: String,
    name: String,
}


impl Role {
    fn from_api(user_id: &str, token: &str) -> Result<Vec<Self>, Box<dyn std::error::Error>> {
        let url = format!(
            "https://api.azrbac.mspim.azure.com/api/v2/privilegedAccess/aadGroups/roleAssignments?$expand=linkedEligibleRoleAssignment,subject,scopedResource,roleDefinition($expand=resource)&$filter=(subject/id eq '{}') and (assignmentState eq 'Eligible')&$count=true",
            user_id
        );
        let client = Client::new();
        let response = client.get(url)
            .bearer_auth(token)
            .send()?
            .text()?;
        
        let content: Value = serde_json::from_str(&response)?;
        let mut eligible_roles = Vec::new();
        
        if let Some(roles) = content["value"].as_array() {
            for role in roles {
                eligible_roles.push(Role {
                    name: role["roleDefinition"]["resource"]["displayName"].as_str().unwrap().to_string(),
                    id: role["id"].as_str().unwrap().to_string(),
                });
            }
        }

        Ok(eligible_roles)
    }
}


fn run_command(command: &str, args: &[&str]) -> String {
    let output = Command::new(command)
        .args(args)
        .output()
        .expect("Failed to execute CLI command");

    str::from_utf8(&output.stdout).unwrap().trim().to_string()
}


fn confirm(message: &str) -> bool {
    Confirm::new(message)
        .with_default(false)
        .prompt()
        .unwrap()
}


fn get_user_eligible_roles() -> Vec<Role> {
    let user_name = run_command("az", &["account", "show", "--query", "user.name", "-o", "tsv"]);
    let user_object_id = run_command("az", &["ad", "user", "show", "--id", &user_name, "--query", "id", "-o", "tsv"]);
    let token = run_command("az", &["account", "get-access-token", "--query", "accessToken", "-o", "tsv"]);

    let eligible_roles: Vec<Role> = Role::from_api(&user_object_id, &token).unwrap();
    
    eligible_roles
}


fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    if let Some(pim_roles) = cli.pim_roles.as_deref() {
        println!("Value for pim_roles: {:?}", pim_roles);
    }

    // Get the user identity and access token from the az CLI tool
    // let user_name = run_command("az", &["account", "show", "--query", "user.name", "-o", "tsv"]);
    // let user_object_id = run_command("az", &["ad", "user", "show", "--id", &user_name, "--query", "id", "-o", "tsv"]);
    // let token = run_command("az", &["account", "get-access-token", "--query", "accessToken", "-o", "tsv"]);

    // let eligible_roles: Vec<Role> = Role::from_api(&user_object_id, &token)?;

    let eligible_roles = get_user_eligible_roles();
    
    let role_names: Vec<String> = eligible_roles.iter().map(|role| role.name.clone()).collect();
    

    // Interactively choose roles to request
    let roles_selection = MultiSelect::new("Which roles do you want to request access to?", role_names)
        .prompt();

    match roles_selection {
        Ok(roles_selection) => {
            println!("You're requresting access to the following roles:");
            for role in roles_selection {
                println!("  -  {}", role);
            }
        },
        Err(err) => {
            println!("Error: {:#?}", err);
        }
    }



    Ok(())
}
